// The one controller that runs a start: get-ready countdown, marks tone, set tone,
// a random hold, the start signal, then automatic stop and save. Screen state, audio and
// recording all follow from `phase`, so nothing can overlap or play twice.
//
// Timing: every step is scheduled against a single clock (host time). The start signal is
// scheduled ahead on the audio device, and its time in the video is estimated as
// (scheduled time + reported output latency) − (time recording started). The video has no
// audio track, so this stays an estimate and is stored with its uncertainty.

import QuartzCore
import SwiftUI

/// What the sequence needs from the camera. `CameraController` is the real one.
/// Not actor-isolated: implementations do their work on their own queues.
protocol StartRecorder: AnyObject {
    /// Starts recording and returns the host time at which recording began.
    func startRecording() async throws -> Double
    func stopRecording() async throws -> URL
    /// Stops and discards any recording in progress.
    func cancelRecording()
}

@MainActor
protocol SequenceClock: AnyObject {
    /// Seconds on the host clock (`CACurrentMediaTime`).
    var now: Double { get }
    func sleep(until time: Double) async throws
}

final class HostClock: SequenceClock {
    var now: Double { CACurrentMediaTime() }
    func sleep(until time: Double) async throws {
        let wait = time - CACurrentMediaTime()
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        try Task.checkCancellation()
    }
}

/// A finished recording handed to the app to save.
struct RecordedStart: Equatable {
    let url: URL
    /// Estimated time of the start signal in the video, seconds.
    let gunTime: Double
    let gunTimeUncertainty: Double
    let holdSeconds: Double
    let repIndex: Int
}

@MainActor
final class StartSequence: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Walking to the blocks. `remaining` whole seconds until the countdown ends.
        case preparing(remaining: Int)
        /// Between reps in repeated mode.
        case resting(remaining: Int)
        case marks
        case set
        /// Start signal fired; still recording.
        case go
        case saving
        /// Rep saved.
        case complete
        /// Stopped without a usable recording, or the save failed. The message is shown on screen.
        case failed(String)
    }

    /// Recording starts this long before the set tone so the whole set position is on video.
    static let preRollSeconds = 2.5
    /// Pause between the end of the countdown and the marks tone.
    static let marksGap = 1.0
    /// The start signal is handed to the audio device this far ahead of time.
    static let scheduleLead = 0.25
    /// Ticks sound in the last few seconds of a countdown (plus one when it begins).
    static let tickSeconds = 5

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var repIndex = 1
    @Published private(set) var repTotal = 1

    private let audio: CuePlaying
    private let recorder: StartRecorder
    private let clock: SequenceClock
    private let randomHold: (ClosedRange<Double>) -> Double

    /// True from Start until the run ends, including the gaps between repeated reps.
    @Published private(set) var isRunning = false
    private var task: Task<Void, Never>? { didSet { isRunning = task != nil } }
    /// A recording is in progress (started and not yet stopped).
    private var recording = false
    /// Set once the start signal has fired, so an interruption after it keeps the recording.
    private var afterGun: (gunTime: Double, uncertainty: Double, hold: Double)?
    private var onRecorded: ((RecordedStart) async throws -> Void)?

    init(audio: CuePlaying, recorder: StartRecorder, clock: SequenceClock? = nil,
         randomHold: @escaping (ClosedRange<Double>) -> Double = { Double.random(in: $0) }) {
        self.audio = audio
        self.recorder = recorder
        self.clock = clock ?? HostClock()
        self.randomHold = randomHold
    }

    /// Starts a run. Ignored while one is already in progress.
    /// `onRecorded` saves each rep; `onFinished` is called after the last rep is saved.
    func start(settings: StartSettings,
               onRecorded: @escaping (RecordedStart) async throws -> Void,
               onFinished: @escaping () -> Void) {
        guard task == nil else { return }
        let settings = settings.sanitized()
        self.onRecorded = onRecorded
        repTotal = settings.repsPerRun
        repIndex = 1
        audio.stopAll()
        task = Task { [weak self] in
            await self?.run(settings: settings, onFinished: onFinished)
        }
    }

    /// The athlete tapped Cancel at the phone: stop quietly and discard the take.
    func cancel() {
        guard task != nil else { return }
        task?.cancel()
        task = nil
        afterGun = nil
        if recording { recorder.cancelRecording() }
        recording = false
        audio.stopAll()
        audio.finish()
        phase = .idle
    }

    /// Something outside the athlete's control stopped the run (camera failure, interruption,
    /// app sent to the background). They may already be in the blocks and can't see the
    /// screen, so the stop is signalled by the cancel sound. A rep whose start signal already fired is
    /// kept if the recording can still be finished.
    func abort(reason: String) {
        guard task != nil else { return }
        // Already stopping and saving: let that finish rather than racing it.
        if phase == .saving { return }
        task?.cancel()
        task = nil
        audio.stopAll()

        if let gun = afterGun {
            afterGun = nil
            recording = false
            phase = .saving
            let index = repIndex
            Task {
                do {
                    let url = try await recorder.stopRecording()
                    try await onRecorded?(RecordedStart(url: url, gunTime: gun.gunTime, gunTimeUncertainty: gun.uncertainty,
                                                        holdSeconds: gun.hold, repIndex: index))
                    audio.play(.complete)
                    audio.finish()
                    phase = .failed("\(reason) The rep was saved, but the recording may be short.")
                } catch {
                    announceStop()
                    phase = .failed("\(reason) The recording could not be saved.")
                }
            }
            return
        }
        if recording { recorder.cancelRecording() }
        recording = false
        announceStop()
        phase = .failed("\(reason) Nothing was recorded.")
    }

    private func announceStop() {
        audio.play(.cancel)
        audio.finish()
    }

    // MARK: Run

    private func run(settings: StartSettings, onFinished: @escaping () -> Void) async {
        do {
            for rep in 1...repTotal {
                repIndex = rep
                if rep == 1 {
                    try await countdown(seconds: settings.prepSeconds) { .preparing(remaining: $0) }
                } else {
                    try await countdown(seconds: settings.restSeconds) { .resting(remaining: $0) }
                }
                let recorded = try await runRep(settings: settings, index: rep)
                afterGun = nil
                do {
                    try await onRecorded?(recorded)
                } catch {
                    throw SequenceError.saveFailed(error.localizedDescription)
                }
                // The last of several reps gets its own sound so the athlete knows the set is over.
                audio.play(rep == repTotal && repTotal > 1 ? .finished : .complete)
                phase = .complete
            }
            audio.finish()
            task = nil
            onFinished()
        } catch is CancellationError {
            // cancel() or abort() already updated the state.
        } catch {
            task = nil
            // Only discard a take that is still recording. A finished file whose save failed
            // stays where it is.
            if recording { recorder.cancelRecording() }
            recording = false
            afterGun = nil
            announceStop()
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Counts down whole seconds, ticking at the start and in the last few seconds, then
    /// plays the "ready" tone that leads into the marks tone.
    private func countdown(seconds: Double, phase makePhase: (Int) -> Phase) async throws {
        let total = max(1, Int(seconds.rounded()))
        let t0 = clock.now
        for k in 0..<total {
            try await clock.sleep(until: t0 + Double(k))
            let remaining = total - k
            phase = makePhase(remaining)
            if k == 0 || remaining <= Self.tickSeconds { audio.play(.tick) }
        }
        try await clock.sleep(until: t0 + Double(total))
        audio.play(.ready)
    }

    private func runRep(settings: StartSettings, index: Int) async throws -> RecordedStart {
        let tMarks = clock.now + Self.marksGap
        try await clock.sleep(until: tMarks)
        phase = .marks
        audio.play(.marks)

        let tSet = tMarks + settings.marksSeconds
        let recordAt = max(tMarks + audio.soundDuration(.marks), tSet - Self.preRollSeconds)
        try await clock.sleep(until: recordAt)
        let recordStart: Double
        do {
            recordStart = try await recorder.startRecording()
            recording = true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SequenceError.cameraFailed
        }

        try await clock.sleep(until: tSet)
        phase = .set
        audio.play(.set)

        // The hold is measured from the end of the set tone. No sound or visual change
        // happens between "Set" and the start signal.
        let hold = randomHold(settings.holdMinSeconds...settings.holdMaxSeconds)
        let gunAt = tSet + audio.soundDuration(.set) + hold
        try await clock.sleep(until: gunAt - Self.scheduleLead)
        let heardAt = audio.play(settings.startSound == .gun ? .gun : .tone, atHostTime: gunAt)
        let gunTime = max(0, heardAt - recordStart)
        let uncertainty = audio.timingUncertainty
        afterGun = (gunTime, uncertainty, hold)

        try await clock.sleep(until: gunAt)
        phase = .go
        try await clock.sleep(until: gunAt + settings.postGunSeconds)

        phase = .saving
        let url: URL
        do {
            url = try await recorder.stopRecording()
            recording = false
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            recording = false
            afterGun = nil
            throw SequenceError.recordingFailed
        }
        return RecordedStart(url: url, gunTime: gunTime, gunTimeUncertainty: uncertainty, holdSeconds: hold, repIndex: index)
    }
}

enum SequenceError: LocalizedError, Equatable {
    case cameraFailed
    case recordingFailed
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .cameraFailed: "The camera couldn't start recording, so the start was cancelled before the set tone."
        case .recordingFailed: "The recording didn't finish properly and couldn't be saved."
        case let .saveFailed(reason): reason
        }
    }
}

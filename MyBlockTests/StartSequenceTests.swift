import XCTest
@testable import MyBlock

// MARK: - Fakes

/// Time only moves when the sequence sleeps. Actions fire once their time is reached,
/// which lets a test cancel or abort at an exact point in the sequence.
@MainActor
final class FakeClock: SequenceClock {
    var now: Double = 100
    private var actions: [(time: Double, run: () -> Void)] = []

    func at(_ time: Double, _ run: @escaping () -> Void) { actions.append((time, run)) }

    func sleep(until time: Double) async throws {
        if time > now { now = time }
        let due = actions.filter { $0.time <= now }
        actions.removeAll { $0.time <= now }
        due.forEach { $0.run() }
        await Task.yield()
        try Task.checkCancellation()
    }
}

final class FakeAudio: CuePlaying {
    struct Event: Equatable { let cue: Cue; let at: Double? }
    var events: [Event] = []
    var stopCount = 0
    let latency = 0.01
    var played: [Cue] { events.map(\.cue) }

    func play(_ cue: Cue) { events.append(Event(cue: cue, at: nil)) }
    func play(_ cue: Cue, atHostTime: Double) -> Double {
        events.append(Event(cue: cue, at: atHostTime))
        return atHostTime + latency
    }
    func soundDuration(_ cue: Cue) -> Double { cue == .set ? 0.5 : (cue == .marks ? 1.0 : 0) }
    var timingUncertainty: Double { 0.05 }
    func stopAll() { stopCount += 1 }
    func finish() {}
}

final class FakeRecorder: StartRecorder {
    let clock: FakeClock
    var startError: Error?
    var stopError: Error?
    var startTimes: [Double] = []
    var stopCount = 0
    var cancelCount = 0
    let url = URL(fileURLWithPath: "/tmp/fake.mov")

    init(clock: FakeClock) { self.clock = clock }

    func startRecording() async throws -> Double {
        if let startError { throw startError }
        let t = await MainActor.run { clock.now }
        startTimes.append(t)
        return t
    }

    func stopRecording() async throws -> URL {
        stopCount += 1
        if let stopError { throw stopError }
        return url
    }

    func cancelRecording() { cancelCount += 1 }
}

struct TestError: Error {}

// MARK: - Tests

@MainActor
final class StartSequenceTests: XCTestCase {
    var clock: FakeClock!
    var audio: FakeAudio!
    var recorder: FakeRecorder!
    var holdRanges: [ClosedRange<Double>] = []
    var sequence: StartSequence!
    var recorded: [RecordedStart] = []
    var finished = false
    var saveError: Error?

    override func setUp() async throws {
        clock = FakeClock()
        audio = FakeAudio()
        recorder = FakeRecorder(clock: clock)
        holdRanges = []
        recorded = []
        finished = false
        saveError = nil
        sequence = StartSequence(audio: audio, recorder: recorder, clock: clock) { [unowned self] range in
            holdRanges.append(range)
            return range.lowerBound + 0.3
        }
    }

    private var settings: StartSettings {
        var s = StartSettings()
        s.prepSeconds = 5
        s.marksSeconds = 6
        s.holdMinSeconds = 1.5
        s.holdMaxSeconds = 2.5
        s.postGunSeconds = 3
        return s
    }

    private func start(_ s: StartSettings? = nil) {
        sequence.start(settings: s ?? settings, onRecorded: { [unowned self] r in
            if let saveError { throw saveError }
            recorded.append(r)
        }, onFinished: { [unowned self] in finished = true })
    }

    /// Lets the sequence run until it stops (or a safety limit is hit).
    private func settle() async {
        for _ in 0..<20000 {
            await Task.yield()
            if !sequence.isRunning { break }
        }
        for _ in 0..<50 { await Task.yield() }
    }

    func testFullRepPlaysCommandsInOrderAndSaves() async {
        let t0 = clock.now
        start()
        await settle()

        XCTAssertTrue(finished)
        XCTAssertEqual(sequence.phase, .complete)
        // Ticks during the countdown, then ready → marks → set → gun → complete. Nothing between set and gun.
        let afterCountdown = Array(audio.played.drop { $0 == .tick })
        XCTAssertEqual(afterCountdown, [.ready, .marks, .set, .gun, .complete])
        XCTAssertEqual(audio.played.filter { $0 == .tick }.count, 5)

        // Timeline: countdown 5 s, 1 s gap, marks, 6 s in blocks, set, 0.5 s set tone + 1.8 s hold.
        let tMarks = t0 + 5 + StartSequence.marksGap
        let tSet = tMarks + 6
        let gunAt = tSet + 0.5 + 1.8
        XCTAssertEqual(audio.events.first { $0.cue == .gun }?.at ?? 0, gunAt, accuracy: 1e-9)

        XCTAssertEqual(recorder.startTimes.count, 1)
        XCTAssertEqual(recorder.startTimes[0], tSet - StartSequence.preRollSeconds, accuracy: 1e-9)
        XCTAssertEqual(recorder.stopCount, 1)
        XCTAssertEqual(recorder.cancelCount, 0)
        XCTAssertEqual(clock.now, gunAt + 3, accuracy: 1e-9, "stops automatically after the post-start time")

        XCTAssertEqual(recorded.count, 1)
        let r = recorded[0]
        // Estimated time in the video = heard-at (scheduled + latency) − recording start.
        XCTAssertEqual(r.gunTime, gunAt + audio.latency - recorder.startTimes[0], accuracy: 1e-9)
        XCTAssertEqual(r.holdSeconds, 1.8, accuracy: 1e-9)
        XCTAssertEqual(r.gunTimeUncertainty, 0.05)
    }

    func testHoldUsesConfiguredRangeAndToneOption() async {
        var s = settings
        s.startSound = .tone
        start(s)
        await settle()
        XCTAssertEqual(holdRanges, [1.5...2.5])
        XCTAssertTrue(audio.played.contains(.tone))
        XCTAssertFalse(audio.played.contains(.gun))
    }

    func testUserCancelDuringCountdownIsQuietAndRecordsNothing() async {
        clock.at(clock.now + 2) { [unowned self] in sequence.cancel() }
        start()
        await settle()
        XCTAssertEqual(sequence.phase, .idle)
        XCTAssertFalse(audio.played.contains(.marks))
        XCTAssertFalse(audio.played.contains(.gun))
        XCTAssertFalse(audio.played.contains(.cancel), "cancel at the phone needs no audible alarm")
        XCTAssertTrue(recorder.startTimes.isEmpty)
        XCTAssertTrue(recorded.isEmpty)
        XCTAssertFalse(finished)
    }

    func testCameraFailureStopsBeforeSetWithAudibleCue() async {
        recorder.startError = TestError()
        start()
        await settle()
        guard case .failed = sequence.phase else { return XCTFail("expected failed, got \(sequence.phase)") }
        XCTAssertTrue(audio.played.contains(.marks))
        XCTAssertFalse(audio.played.contains(.set), "must not continue into Set without a recording")
        XCTAssertFalse(audio.played.contains(.gun))
        XCTAssertTrue(audio.played.contains(.cancel))
        XCTAssertTrue(recorded.isEmpty)
    }

    func testInterruptionInTheBlocksAbortsAudibly() async {
        // 5 s countdown + 1 s gap + 4 s into the marks period: in the blocks, pre-roll recording running.
        clock.at(clock.now + 10) { [unowned self] in sequence.abort(reason: "Interrupted.") }
        start()
        await settle()
        XCTAssertEqual(sequence.phase, .failed("Interrupted. Nothing was recorded."))
        XCTAssertFalse(audio.played.contains(.gun))
        XCTAssertTrue(audio.played.contains(.cancel))
        XCTAssertEqual(recorder.cancelCount, 1)
        XCTAssertTrue(recorded.isEmpty)
    }

    func testInterruptionAfterStartSignalKeepsTheRecording() async {
        let gunAt = clock.now + 5 + StartSequence.marksGap + 6 + 0.5 + 1.8
        clock.at(gunAt + 1) { [unowned self] in sequence.abort(reason: "Closed.") }
        start()
        await settle()
        XCTAssertTrue(audio.played.contains(.gun))
        XCTAssertEqual(recorded.count, 1, "a rep whose start already fired is saved")
        XCTAssertEqual(recorder.cancelCount, 0)
        XCTAssertFalse(audio.played.contains(.cancel))
    }

    func testRecordingFailureAfterGunIsReportedAudibly() async {
        recorder.stopError = TestError()
        start()
        await settle()
        XCTAssertEqual(sequence.phase, .failed(SequenceError.recordingFailed.errorDescription!))
        XCTAssertTrue(audio.played.contains(.cancel))
        XCTAssertTrue(recorded.isEmpty)
    }

    func testSaveFailureDoesNotDiscardTheFile() async {
        saveError = RepStore.StoreError.saveFailed("Disk full.")
        start()
        await settle()
        guard case let .failed(message) = sequence.phase else { return XCTFail("expected failed") }
        XCTAssertTrue(message.contains("Disk full."))
        XCTAssertEqual(recorder.cancelCount, 0, "cancelRecording would delete the finished file")
        XCTAssertTrue(audio.played.contains(.cancel))
    }

    func testSecondStartWhileRunningIsIgnored() async {
        start()
        start()
        await settle()
        XCTAssertEqual(audio.played.filter { $0 == .marks }.count, 1)
        XCTAssertEqual(audio.played.filter { $0 == .gun }.count, 1)
        XCTAssertEqual(recorded.count, 1)
    }

    func testRepeatedModeRunsSelectedCountThenStops() async {
        var s = settings
        s.repeatEnabled = true
        s.repeatCount = 3
        s.restSeconds = 30
        start(s)
        await settle()
        XCTAssertTrue(finished)
        XCTAssertEqual(recorded.map(\.repIndex), [1, 2, 3])
        XCTAssertEqual(audio.played.filter { $0 == .gun }.count, 3)
        XCTAssertEqual(audio.played.filter { $0 == .complete }.count, 2)
        XCTAssertEqual(audio.played.last, .finished, "the last rep gets its own sound")
        XCTAssertEqual(audio.played.filter { $0 == .ready }.count, 3, "a tone leads into every rep")
    }

    func testRepeatedModeStopsOnErrorInsteadOfContinuing() async {
        var s = settings
        s.repeatEnabled = true
        s.repeatCount = 3
        s.restSeconds = 30
        saveError = TestError()
        start(s)
        await settle()
        guard case .failed = sequence.phase else { return XCTFail("expected failed") }
        XCTAssertEqual(audio.played.filter { $0 == .gun }.count, 1)
        XCTAssertFalse(finished)
    }
}

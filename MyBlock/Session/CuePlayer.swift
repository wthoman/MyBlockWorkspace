// Plays the start tones, countdown ticks and status sounds from bundled files. No voice.
// All audio work runs on a private serial queue, never the main thread.

import AudioToolbox
import AVFoundation
import os
import QuartzCore
import SwiftUI

/// Every sound MyBlock makes. All are tones from bundled files: no voice.
enum Cue: String, CaseIterable {
    /// Soft tick during the get-ready countdown.
    case tick
    /// End of the countdown; the marks tone follows.
    case ready
    /// Two rising notes: get into the blocks.
    case marks
    /// One firm note: rise into the set position.
    case set
    /// Start signals.
    case gun, tone
    /// The rep was recorded and saved.
    case complete
    /// Three rising notes: the last of several reps is saved.
    case finished
    /// Three falling notes: the rep was stopped and not recorded.
    case cancel

    /// System sound used when a file is missing from the bundle.
    var fallbackSystemSound: SystemSoundID {
        switch self {
        case .tick: 1103
        case .ready, .marks, .set, .tone, .gun: 1057
        case .complete, .finished: 1025
        case .cancel: 1073
        }
    }
}

/// What the start sequence needs from audio. `CuePlayer` is the real one; tests use a fake.
protocol CuePlaying: AnyObject {
    func play(_ cue: Cue)
    /// Schedules `cue` at a host time (`CACurrentMediaTime` clock) and returns the host time it
    /// is expected to be heard, including the output latency the system reports.
    func play(_ cue: Cue, atHostTime: Double) -> Double
    /// Seconds from the start of a cue to the end of its audible sound.
    func soundDuration(_ cue: Cue) -> Double
    /// ± seconds on the "heard at" estimate for the current audio route.
    var timingUncertainty: Double { get }
    func stopAll()
    /// Lets other apps' audio resume once the last sound has finished.
    func finish()
}

final class CuePlayer: NSObject, CuePlaying, @unchecked Sendable {
    static let shared = CuePlayer()

    /// Values the start sequence reads synchronously from the main thread. They are produced
    /// on `queue` (audio work that can block) and read through a lock, so the main thread never
    /// touches AVAudioPlayer setup or AVAudioSession.
    private struct Cached {
        var soundEnds: [Cue: Double] = [:]
        var outputLatency: Double = 0.01
        var wirelessRoute = false
        /// Cues with no bundled file; playback falls back to system sounds.
        var missing: [Cue] = []
    }

    private let queue = DispatchQueue(label: "myblock.cues", qos: .userInteractive)
    private let cache = OSAllocatedUnfairLock(initialState: Cached())
    // Only touched on `queue`.
    private var players: [Cue: AVAudioPlayer] = [:]
    private var active = false
    private var deactivateToken = 0
    private var routeObserver: NSObjectProtocol?

    /// Cues with no bundled file.
    var missing: [Cue] { cache.withLock { $0.missing } }

    override init() {
        super.init()
        // Loading and preparing players can block, so it never runs on the caller's thread.
        // Every later play call is queued behind this.
        queue.async { self.loadPlayers() }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.refreshRoute() }
        }
    }

    deinit {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    }

    private func loadPlayers() {
        var ends: [Cue: Double] = [:]
        var missing: [Cue] = []
        for cue in Cue.allCases {
            guard let url = Bundle.main.url(forResource: cue.rawValue, withExtension: "wav"),
                  let player = try? AVAudioPlayer(contentsOf: url) else {
                missing.append(cue)
                continue
            }
            player.prepareToPlay()
            players[cue] = player
            ends[cue] = Self.lastSoundTime(in: url) ?? player.duration
        }
        let loaded = ends, absent = missing
        cache.withLock {
            $0.soundEnds = loaded
            $0.missing = absent
        }
        refreshRoute()
    }

    /// Reads the output latency and route type. Runs on `queue`.
    private func refreshRoute() {
        let session = AVAudioSession.sharedInstance()
        let latency = session.outputLatency
        let wireless: [AVAudioSession.Port] = [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .airPlay]
        let isWireless = session.currentRoute.outputs.contains { wireless.contains($0.portType) }
        cache.withLock {
            $0.outputLatency = latency
            $0.wirelessRoute = isWireless
        }
    }

    /// Time of the last sample above a quiet threshold, so trailing silence in a file
    /// doesn't lengthen the hold after the set tone.
    private static func lastSoundTime(in url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let data = buffer.floatChannelData?[0] else { return nil }
        let n = Int(buffer.frameLength)
        var last = 0
        for i in stride(from: n - 1, through: 0, by: -1) where abs(data[i]) > 0.02 {
            last = i
            break
        }
        return Double(last) / file.processingFormat.sampleRate
    }

    // MARK: Session

    /// `.playback` so cues are heard even with the silent switch on. Activated only when a
    /// sound is about to play, so opening the app doesn't stop the athlete's music.
    private func activateOnQueue() {
        deactivateToken += 1
        guard !active else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        active = true
        refreshRoute()
    }

    func finish() {
        queue.async {
            self.deactivateToken += 1
            let token = self.deactivateToken
            // Give the last cue time to finish.
            self.queue.asyncAfter(deadline: .now() + 4) {
                guard token == self.deactivateToken, self.active else { return }
                if self.players.values.contains(where: \.isPlaying) { return }
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                self.active = false
            }
        }
    }

    // MARK: Playback

    func play(_ cue: Cue) {
        queue.async {
            self.activateOnQueue()
            self.playOnQueue(cue, deviceTime: nil)
        }
    }

    func play(_ cue: Cue, atHostTime host: Double) -> Double {
        let latency = cache.withLock { $0.outputLatency }
        queue.async {
            self.activateOnQueue()
            self.playOnQueue(cue, deviceTime: host)
        }
        return host + latency
    }

    /// `hostTime` is converted to the player's own clock at the last moment.
    private func playOnQueue(_ cue: Cue, deviceTime hostTime: Double?) {
        guard let player = players[cue] ?? (cue == .gun ? players[.tone] : nil) else {
            AudioServicesPlaySystemSound(cue.fallbackSystemSound)
            return
        }
        player.stop()
        player.currentTime = 0
        if let hostTime {
            let delay = max(0, hostTime - CACurrentMediaTime())
            player.play(atTime: player.deviceCurrentTime + delay)
        } else {
            player.play()
        }
    }

    func soundDuration(_ cue: Cue) -> Double {
        if let end = cache.withLock({ $0.soundEnds[cue] }) { return end }
        // Not loaded yet (loading takes milliseconds) or the file is missing: typical lengths.
        switch cue {
        case .marks: return 0.65
        case .set: return 0.3
        default: return 0
        }
    }

    var timingUncertainty: Double {
        // Wireless routes add a large delay that the reported latency only partly covers.
        cache.withLock { $0.wirelessRoute } ? 0.25 : 0.05
    }

    func stopAll() {
        queue.async {
            for player in self.players.values { player.stop() }
        }
    }
}

/// Plays the marks tone, the set tone and the start sound back to back so the athlete can check
/// their volume. Uses the real device output, so it reflects the current volume and route.
@MainActor
final class SoundTest: ObservableObject {
    static let shared = SoundTest()
    @Published private(set) var isPlaying = false
    private var task: Task<Void, Never>?

    func play(startSound: StartSound, audio: CuePlayer = .shared) {
        guard !isPlaying else { return }
        isPlaying = true
        task = Task {
            let t0 = CACurrentMediaTime() + 0.1
            _ = audio.play(.marks, atHostTime: t0)
            let tSet = t0 + audio.soundDuration(.marks) + 0.8
            _ = audio.play(.set, atHostTime: tSet)
            let tStart = tSet + audio.soundDuration(.set) + 1.2
            _ = audio.play(startSound == .gun ? .gun : .tone, atHostTime: tStart)
            try? await Task.sleep(for: .seconds(tStart - CACurrentMediaTime() + 0.8))
            audio.finish()
            isPlaying = false
        }
    }

    func playSingle(_ cue: Cue, audio: CuePlayer = .shared) {
        guard !isPlaying else { return }
        audio.play(cue)
        audio.finish()
    }

    func stop(audio: CuePlayer = .shared) {
        task?.cancel()
        task = nil
        audio.stopAll()
        isPlaying = false
    }
}

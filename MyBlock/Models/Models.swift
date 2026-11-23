import Foundation

/// Body joints reported by Apple Vision's body-pose detector that MyBlock uses.
enum Joint: String, CaseIterable, Hashable, Codable {
    case nose, neck
    case leftShoulder, rightShoulder
    case leftElbow, rightElbow
    case leftWrist, rightWrist
    case root
    case leftHip, rightHip
    case leftKnee, rightKnee
    case leftAnkle, rightAnkle
}

/// One detected joint. `x` and `y` are normalized 0...1 with the origin at the top-left of the image.
struct Landmark: Equatable, Codable {
    var x: Double
    var y: Double
    /// Detector confidence, 0...1.
    var confidence: Double
}

typealias Pose = [Joint: Landmark]

enum Grade: String, Codable {
    case green, yellow, red, unknown
}

enum FrameKind: String, CaseIterable, Identifiable, Hashable, Codable {
    case set, clearance
    var id: String { rawValue }

    var title: String {
        switch self {
        case .set: "Set position"
        case .clearance: "Block clearance"
        }
    }

    var shortTitle: String {
        switch self {
        case .set: "Set"
        case .clearance: "Clearance"
        }
    }
}

struct MetricResult: Identifiable, Equatable {
    let id: MetricID
    let label: String
    /// Measured angle in degrees, or nil when the joints were not visible enough.
    let value: Int?
    let grade: Grade
    /// Human-readable guide range, e.g. "85–105°".
    let target: String
    /// One-line coaching cue for this result.
    let cue: String
    /// Joint where the grade dot is drawn.
    let anchor: Joint

    var isAssessed: Bool { grade != .unknown }
}

/// Sound that fires the start.
enum StartSound: String, Codable, CaseIterable, Identifiable {
    case gun, tone
    var id: String { rawValue }
    var title: String {
        switch self {
        case .gun: "Starting gun"
        case .tone: "Electronic tone"
        }
    }
}

/// Everything the athlete can tune. Stored in UserDefaults by `SettingsStore`.
struct StartSettings: Equatable, Codable {
    /// Seconds between tapping Start and the end of the "get ready" countdown (time to walk to the blocks).
    var prepSeconds: Double = 15
    /// Seconds between the marks tone and the set tone (time to settle into the blocks).
    var marksSeconds: Double = 12
    /// Shortest and longest hold between the end of the set tone and the start signal, seconds.
    var holdMinSeconds: Double = 1.8
    var holdMaxSeconds: Double = 2.8
    var startSound: StartSound = .gun
    /// Seconds recorded after the start signal (clearance and first steps).
    var postGunSeconds: Double = 3
    /// Large full-screen state text ("SET", "GO") over the camera preview.
    var largeCues = true
    /// Optional repeated reps. Off by default.
    var repeatEnabled = false
    var repeatCount = 3
    var restSeconds: Double = 90

    static let prepRange: ClosedRange<Double> = 5...60
    static let marksRange: ClosedRange<Double> = 5...30
    static let holdRange: ClosedRange<Double> = 1.0...4.0
    /// The randomized window is never narrower than this, so the start stays unpredictable.
    static let minHoldSpread = 0.4
    static let postGunRange: ClosedRange<Double> = 2...6
    static let repeatCountRange: ClosedRange<Int> = 2...10
    static let restRange: ClosedRange<Double> = 30...300

    init() {}

    /// Decodes leniently so settings saved by an older version keep working.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StartSettings()
        prepSeconds = try c.decodeIfPresent(Double.self, forKey: .prepSeconds) ?? d.prepSeconds
        marksSeconds = try c.decodeIfPresent(Double.self, forKey: .marksSeconds) ?? d.marksSeconds
        holdMinSeconds = try c.decodeIfPresent(Double.self, forKey: .holdMinSeconds) ?? d.holdMinSeconds
        holdMaxSeconds = try c.decodeIfPresent(Double.self, forKey: .holdMaxSeconds) ?? d.holdMaxSeconds
        startSound = (try? c.decodeIfPresent(StartSound.self, forKey: .startSound)) ?? d.startSound
        postGunSeconds = try c.decodeIfPresent(Double.self, forKey: .postGunSeconds) ?? d.postGunSeconds
        largeCues = try c.decodeIfPresent(Bool.self, forKey: .largeCues) ?? d.largeCues
        repeatEnabled = try c.decodeIfPresent(Bool.self, forKey: .repeatEnabled) ?? d.repeatEnabled
        repeatCount = try c.decodeIfPresent(Int.self, forKey: .repeatCount) ?? d.repeatCount
        restSeconds = try c.decodeIfPresent(Double.self, forKey: .restSeconds) ?? d.restSeconds
        self = sanitized()
    }

    /// Clamps every value into its allowed range and keeps the hold window valid.
    func sanitized() -> StartSettings {
        var s = self
        func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(r.upperBound, max(r.lowerBound, v)) }
        s.prepSeconds = clamp(prepSeconds, Self.prepRange)
        s.marksSeconds = clamp(marksSeconds, Self.marksRange)
        s.postGunSeconds = clamp(postGunSeconds, Self.postGunRange)
        s.restSeconds = clamp(restSeconds, Self.restRange)
        s.repeatCount = min(Self.repeatCountRange.upperBound, max(Self.repeatCountRange.lowerBound, repeatCount))
        s.holdMinSeconds = clamp(holdMinSeconds, Self.holdRange.lowerBound...(Self.holdRange.upperBound - Self.minHoldSpread))
        s.holdMaxSeconds = clamp(holdMaxSeconds, (s.holdMinSeconds + Self.minHoldSpread)...Self.holdRange.upperBound)
        return s
    }

    /// Reps in one run of the sequence.
    var repsPerRun: Int { repeatEnabled ? repeatCount : 1 }
}

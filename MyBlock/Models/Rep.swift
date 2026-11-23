import Foundation

/// One saved start: the video plus whatever analysis has been done on it.
struct Rep: Identifiable, Codable, Equatable {
    enum Source: String, Codable { case recorded, imported }

    let id: UUID
    let date: Date
    /// Reps recorded in one visit to the start screen share a session id.
    let sessionID: UUID
    let source: Source
    /// File name of the original video inside the rep's folder.
    let videoFileName: String
    /// Estimated time of the start signal inside the video, seconds. Nil for imported clips.
    let gunTime: Double?
    /// How far off `gunTime` may be, seconds (± value).
    let gunTimeUncertainty: Double?
    /// The random hold that was used between "Set" and the start signal, seconds.
    let holdSeconds: Double?
    var note: String = ""
    /// Analysed frames, keyed by kind. Missing until the rep has been analysed.
    var frames: [FrameKind: RepFrame] = [:]

    var isAnalyzed: Bool { FrameKind.allCases.allSatisfy { frames[$0] != nil } }
}

/// The detected pose for one graded frame. Metrics are recomputed from the pose when shown,
/// so tuning `Scoring` later also updates old reps.
struct RepFrame: Codable, Equatable {
    /// Time of this frame in the video, seconds.
    var time: Double
    /// Size of the analysed image, pixels.
    var width: Double
    var height: Double
    var pose: Pose?
    /// True when the athlete picked this frame by hand instead of the automatic estimate.
    var adjusted: Bool

    var metrics: [MetricResult] {
        Analysis.analyzeFrame(kind: kind, pose: pose, width: width, height: height)
    }

    /// Filled in by `Rep.frame(_:)`; not stored separately because the dictionary key holds it.
    fileprivate(set) var kind: FrameKind = .set

    enum CodingKeys: String, CodingKey { case time, width, height, pose, adjusted, kind }

    init(kind: FrameKind, time: Double, width: Double, height: Double, pose: Pose?, adjusted: Bool) {
        self.kind = kind
        self.time = time
        self.width = width
        self.height = height
        self.pose = pose
        self.adjusted = adjusted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(Double.self, forKey: .time)
        width = try c.decode(Double.self, forKey: .width)
        height = try c.decode(Double.self, forKey: .height)
        adjusted = try c.decodeIfPresent(Bool.self, forKey: .adjusted) ?? false
        kind = try c.decodeIfPresent(FrameKind.self, forKey: .kind) ?? .set
        // Pose dictionaries are stored with joint names as keys.
        if let raw = try c.decodeIfPresent([String: Landmark].self, forKey: .pose) {
            var pose: Pose = [:]
            for (k, v) in raw { if let j = Joint(rawValue: k) { pose[j] = v } }
            self.pose = pose.isEmpty ? nil : pose
        } else {
            pose = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(time, forKey: .time)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(adjusted, forKey: .adjusted)
        try c.encode(kind, forKey: .kind)
        if let pose {
            try c.encode(Dictionary(uniqueKeysWithValues: pose.map { ($0.key.rawValue, $0.value) }), forKey: .pose)
        }
    }
}

extension Rep {
    // Frames are stored as a [String: RepFrame] map so the JSON stays readable.
    enum CodingKeys: String, CodingKey {
        case id, date, sessionID, source, videoFileName, gunTime, gunTimeUncertainty, holdSeconds, note, frames
    }

    init(id: UUID = UUID(), date: Date = Date(), sessionID: UUID, source: Source, videoFileName: String,
         gunTime: Double?, gunTimeUncertainty: Double?, holdSeconds: Double?) {
        self.id = id
        self.date = date
        self.sessionID = sessionID
        self.source = source
        self.videoFileName = videoFileName
        self.gunTime = gunTime
        self.gunTimeUncertainty = gunTimeUncertainty
        self.holdSeconds = holdSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        sessionID = try c.decode(UUID.self, forKey: .sessionID)
        source = try c.decode(Source.self, forKey: .source)
        videoFileName = try c.decode(String.self, forKey: .videoFileName)
        gunTime = try c.decodeIfPresent(Double.self, forKey: .gunTime)
        gunTimeUncertainty = try c.decodeIfPresent(Double.self, forKey: .gunTimeUncertainty)
        holdSeconds = try c.decodeIfPresent(Double.self, forKey: .holdSeconds)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        let raw = try c.decodeIfPresent([String: RepFrame].self, forKey: .frames) ?? [:]
        var frames: [FrameKind: RepFrame] = [:]
        for (k, v) in raw {
            guard let kind = FrameKind(rawValue: k) else { continue }
            var frame = v
            frame.kind = kind
            frames[kind] = frame
        }
        self.frames = frames
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(date, forKey: .date)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(source, forKey: .source)
        try c.encode(videoFileName, forKey: .videoFileName)
        try c.encodeIfPresent(gunTime, forKey: .gunTime)
        try c.encodeIfPresent(gunTimeUncertainty, forKey: .gunTimeUncertainty)
        try c.encodeIfPresent(holdSeconds, forKey: .holdSeconds)
        try c.encode(note, forKey: .note)
        try c.encode(Dictionary(uniqueKeysWithValues: frames.map { ($0.key.rawValue, $0.value) }), forKey: .frames)
    }

    /// Short summary for history rows, e.g. "Set 4/6 · Clearance 3/4".
    var summary: String {
        guard isAnalyzed else { return "Not analysed yet" }
        return FrameKind.allCases.map { kind in
            let metrics = frames[kind]?.metrics ?? []
            let assessed = metrics.filter(\.isAssessed)
            if assessed.isEmpty { return "\(kind.shortTitle) –" }
            return "\(kind.shortTitle) \(assessed.filter { $0.grade == .green }.count)/\(assessed.count)"
        }.joined(separator: " · ")
    }
}

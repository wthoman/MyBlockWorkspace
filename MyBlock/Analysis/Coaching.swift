// Picks the one thing to work on next and summarises how much of a frame could be assessed.
// Pure functions only. Missing joints never count against the athlete: they are reported
// as "Unable to assess", not as a low grade.

import Foundation

struct FrameSummary: Equatable {
    let total: Int
    let assessed: Int
    let inRange: Int

    init(metrics: [MetricResult]) {
        total = metrics.count
        assessed = metrics.filter(\.isAssessed).count
        inRange = metrics.filter { $0.grade == .green }.count
    }

    var canAssess: Bool { assessed > 0 }
    /// Some measurements could be taken, but not all.
    var isPartial: Bool { assessed > 0 && assessed < total }

    /// "4 of 6 in guide range", or "Unable to assess".
    var headline: String {
        canAssess ? "\(inRange) of \(assessed) in guide range" : "Unable to assess"
    }

    /// Short line about analysis confidence, nil when everything was measured.
    var confidenceNote: String? {
        if !canAssess { return "Joints weren't clear enough in this frame." }
        if isPartial { return "\(total - assessed) of \(total) couldn't be measured and aren't counted." }
        return nil
    }
}

struct MainCue: Equatable {
    let text: String
    /// Which frame and measurement it comes from, nil for general advice.
    let kind: FrameKind?
    let metric: MetricID?
}

enum Coaching {
    /// One cue for the next rep. Order: set-position issues outside the wider range, then
    /// clearance ones, then set-position near misses, then clearance near misses.
    /// The set position comes first because it's the part the athlete sets up deliberately.
    static func mainCue(set: [MetricResult]?, clearance: [MetricResult]?) -> MainCue {
        let groups: [(FrameKind, [MetricResult])] = [(.set, set ?? []), (.clearance, clearance ?? [])]
        for grade in [Grade.red, .yellow] {
            for (kind, metrics) in groups {
                if let m = metrics.first(where: { $0.grade == grade }) {
                    return MainCue(text: m.cue, kind: kind, metric: m.id)
                }
            }
        }
        let anyAssessed = groups.contains { $0.1.contains(where: \.isAssessed) }
        if !anyAssessed {
            return MainCue(
                text: "Your joints weren't clear enough to measure. Set the phone level and side-on, with your whole body in frame.",
                kind: nil, metric: nil
            )
        }
        return MainCue(text: "Everything measured was inside the guide ranges. Keep this setup and repeat it.",
                       kind: nil, metric: nil)
    }

    /// "0.10 s before the start · ±0.05 s" label for a frame time, or nil without a start time.
    static func relativeTimeText(time: Double, gunTime: Double?, uncertainty: Double?) -> String? {
        guard let gunTime else { return nil }
        let d = time - gunTime
        let value = String(format: "%.2f s", abs(d))
        let side = abs(d) < 0.005 ? "At the start" : (d < 0 ? "\(value) before the start" : "\(value) after the start")
        guard let uncertainty else { return side }
        return "\(side) · ±\(String(format: "%.2f", uncertainty)) s"
    }
}

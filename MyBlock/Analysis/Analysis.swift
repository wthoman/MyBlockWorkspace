// Turns pose landmarks from one side-on frame into graded checkpoints.
// Pure functions only: no UI, no device APIs.

import Foundation

enum Analysis {
    struct Point {
        var x: Double
        var y: Double
        /// Confidence, 0 when the joint was not detected.
        var c: Double
    }

    private static func deg(_ rad: Double) -> Double { rad * 180 / .pi }

    /// Interior angle at b, in degrees, between segments b→a and b→c.
    static func jointAngle(_ a: Point, _ b: Point, _ c: Point) -> Double {
        let v1x = a.x - b.x, v1y = a.y - b.y
        let v2x = c.x - b.x, v2y = c.y - b.y
        let dot = v1x * v2x + v1y * v2y
        let mag = hypot(v1x, v1y) * hypot(v2x, v2y)
        if mag == 0 { return .nan }
        return deg(acos(max(-1, min(1, dot / mag))))
    }

    private static func mid(_ a: Point, _ b: Point) -> Point {
        Point(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, c: min(a.c, b.c))
    }

    private static func grade(_ value: Double, _ spec: MetricSpec) -> Grade {
        if spec.green.contains(value) { return .green }
        if spec.yellow.contains(value) { return .yellow }
        return .red
    }

    static func targetText(_ spec: MetricSpec) -> String {
        let lo = Int(spec.green.lowerBound), hi = Int(spec.green.upperBound)
        return hi >= 180 ? "\(lo)°+" : "\(lo)–\(hi)°"
    }

    private struct Leg {
        let hip: Joint, knee: Joint, ankle: Joint
    }

    private struct Measured {
        var value: Double
        var visible: Bool
        var anchor: Joint
    }

    /// Grades one frame. `width` and `height` are the image size in pixels, so angles are
    /// not distorted by the aspect ratio of the normalized landmark coordinates.
    static func analyzeFrame(kind: FrameKind, pose: Pose?, width: Double, height: Double) -> [MetricResult] {
        let specs = Scoring.specs(for: kind)
        guard let pose, !pose.isEmpty else {
            return specs.map {
                MetricResult(id: $0.id, label: $0.label, value: nil, grade: .unknown, target: targetText($0),
                             cue: "Unable to assess: no athlete was found in this frame.", anchor: .leftHip)
            }
        }

        func p(_ j: Joint) -> Point {
            guard let l = pose[j] else { return Point(x: 0, y: 0, c: 0) }
            return Point(x: l.x * width, y: l.y * height, c: l.confidence)
        }
        let minC = Scoring.minConfidence

        let shoulder = mid(p(.leftShoulder), p(.rightShoulder))
        let hip = mid(p(.leftHip), p(.rightHip))
        // +1 when the athlete faces right in the image, -1 when facing left.
        // In both "set" and at block exit the shoulders are ahead of the hips.
        let dir: Double = shoulder.x >= hip.x ? 1 : -1

        let left = Leg(hip: .leftHip, knee: .leftKnee, ankle: .leftAnkle)
        let right = Leg(hip: .rightHip, knee: .rightKnee, ankle: .rightAnkle)
        // The forward leg has its foot furthest toward the finish.
        let leftIsForward = p(left.ankle).x * dir >= p(right.ankle).x * dir
        let forwardLeg = leftIsForward ? left : right
        let backLeg = leftIsForward ? right : left

        func knee(_ leg: Leg) -> Measured {
            let h = p(leg.hip), k = p(leg.knee), a = p(leg.ankle)
            return Measured(value: jointAngle(h, k, a), visible: min(h.c, k.c, a.c) >= minC, anchor: leg.knee)
        }
        func hipAngle(_ leg: Leg) -> Measured {
            let h = p(leg.hip), k = p(leg.knee)
            return Measured(value: jointAngle(shoulder, h, k), visible: min(shoulder.c, h.c, k.c) >= minC, anchor: leg.hip)
        }

        var measured: [MetricID: Measured] = [:]

        switch kind {
        case .set:
            // In "set" the front-block leg is the one with its foot nearer the start line.
            measured[.frontKnee] = knee(forwardLeg)
            measured[.rearKnee] = knee(backLeg)
            measured[.frontHip] = hipAngle(forwardLeg)
            measured[.rearHip] = hipAngle(backLeg)
            measured[.hipHeight] = Measured(
                value: deg(atan2(shoulder.y - hip.y, abs(shoulder.x - hip.x))),
                visible: min(shoulder.c, hip.c) >= minC,
                anchor: forwardLeg.hip
            )
            let wristJoint: Joint = p(.leftWrist).c >= p(.rightWrist).c ? .leftWrist : .rightWrist
            let wrist = p(wristJoint)
            measured[.shoulderLead] = Measured(
                value: deg(atan2((shoulder.x - wrist.x) * dir, wrist.y - shoulder.y)),
                visible: min(shoulder.c, wrist.c) >= minC,
                anchor: wristJoint == .leftWrist ? .leftShoulder : .rightShoulder
            )

        case .clearance:
            // At block exit the front-block (push) leg is the one trailing behind;
            // the rear-block leg has already swung forward.
            let push = backLeg
            let swing = forwardLeg
            measured[.pushKnee] = knee(push)
            measured[.pushHip] = hipAngle(push)
            let ankle = p(push.ankle)
            measured[.driveAngle] = Measured(
                value: deg(atan2(ankle.y - shoulder.y, (shoulder.x - ankle.x) * dir)),
                visible: min(shoulder.c, ankle.c) >= minC,
                anchor: push.ankle
            )
            var swingHip = hipAngle(swing)
            swingHip.anchor = swing.knee
            measured[.swingHip] = swingHip
        }

        return specs.map { spec in
            guard let m = measured[spec.id], m.visible, !m.value.isNaN else {
                return MetricResult(
                    id: spec.id, label: spec.label, value: nil, grade: .unknown, target: targetText(spec),
                    cue: "Unable to assess: these joints weren't clearly visible.",
                    anchor: measured[spec.id]?.anchor ?? .leftHip
                )
            }
            let g = grade(m.value, spec)
            let cue = g == .green ? spec.cueGood : (m.value < spec.green.lowerBound ? spec.cueLow : spec.cueHigh)
            return MetricResult(
                id: spec.id, label: spec.label, value: Int((m.value + 0.5).rounded(.down)), grade: g,
                target: targetText(spec), cue: cue, anchor: m.anchor
            )
        }
    }

    /// Skeleton segments drawn on the results image.
    static let skeleton: [(Joint, Joint)] = [
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.leftShoulder, .rightShoulder),
        (.leftShoulder, .leftHip), (.rightShoulder, .rightHip),
        (.leftHip, .rightHip),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
    ]
}

// Grading ranges for the block-start form check. Everything here is meant to be tuned.
//
// A value inside `green` is green, inside `yellow` (but outside green) is yellow, otherwise red.
// All knee and hip values are interior joint angles in degrees (180 = fully straight).
//
// EVIDENCE LEVELS
//   .study      – the range is built around values reported in published research.
//   .convention – no published numbers were found; the range follows common coaching
//                 guidance and should be reviewed by someone who coaches sprinters.
//
// Main source: Bezodis, Willwacher & Salo (2019), "The Biomechanics of the Track and Field
// Sprint Start: A Narrative Review", Sports Medicine 49:1345–1364.
// https://pmc.ncbi.nlm.nih.gov/articles/PMC6684547
// The review stresses that no single optimal "set" position exists for all sprinters and
// that set-position angles correlate only weakly with block power, so treat these grades
// as guidance, not as a verdict.

import Foundation

enum MetricID: String {
    case frontKnee, rearKnee, frontHip, rearHip, hipHeight, shoulderLead
    case pushKnee, pushHip, driveAngle, swingHip
}

struct MetricSpec {
    enum Evidence { case study, convention }

    let id: MetricID
    let label: String
    let green: ClosedRange<Double>
    let yellow: ClosedRange<Double>
    let cueGood: String
    let cueLow: String
    let cueHigh: String
    let evidence: Evidence
    let source: String
}

enum Scoring {
    /// Joints below this detector confidence are treated as not seen.
    static let minConfidence = 0.25

    static func specs(for kind: FrameKind) -> [MetricSpec] {
        switch kind {
        case .set: set
        case .clearance: clearance
        }
    }

    static let set: [MetricSpec] = [
        MetricSpec(
            id: .frontKnee,
            label: "Front knee angle",
            green: 85...105,
            yellow: 75...115,
            cueGood: "Front knee is loaded well.",
            cueLow: "Front knee is very bent. Raise your hips or move the front block back.",
            cueHigh: "Front knee is too open. Lower your hips slightly or move the front block forward.",
            evidence: .study,
            source: "Ciacci et al. 2017 (91° vs 99° between groups), via Bezodis et al. 2019"
        ),
        MetricSpec(
            id: .rearKnee,
            label: "Rear knee angle",
            green: 110...136,
            yellow: 100...145,
            cueGood: "Rear knee angle is in the typical range.",
            cueLow: "Rear knee is very bent. Move the rear block back or raise your hips.",
            cueHigh: "Rear leg is nearly straight, so it cannot push much. Move the rear block forward.",
            evidence: .study,
            source: "Slawinski et al. 2010 (117–136°); Ciacci et al. 2017 (114–121°), via Bezodis et al. 2019"
        ),
        MetricSpec(
            id: .frontHip,
            label: "Front hip angle",
            green: 35...55,
            yellow: 28...65,
            cueGood: "Front hip is well flexed and ready to extend.",
            cueLow: "Front hip is very closed. Raise your hips a little.",
            cueHigh: "Front hip is too open. Bring your hips back and down toward your heels.",
            evidence: .study,
            source: "Mero, Luhtanen & Komi 1983 (41° fastest vs 52° slowest), via Bezodis et al. 2019"
        ),
        MetricSpec(
            id: .rearHip,
            label: "Rear hip angle",
            green: 70...95,
            yellow: 60...105,
            cueGood: "Rear hip is in the typical range.",
            cueLow: "Rear hip is very closed. Move the rear block back slightly.",
            cueHigh: "Rear hip is too open. Move the rear block closer or lower your hips.",
            evidence: .study,
            source: "Mero, Luhtanen & Komi 1983 (80° fastest vs 89° slowest), via Bezodis et al. 2019"
        ),
        MetricSpec(
            id: .hipHeight,
            label: "Hips above shoulders",
            // Angle of the hip-to-shoulder line below horizontal. Positive = hips higher.
            green: 5...25,
            yellow: 0...32,
            cueGood: "Hips are above your shoulders.",
            cueLow: "Hips are level with or below your shoulders. Lift your hips in \"set\".",
            cueHigh: "Hips are very high. Lower them a little so your legs can push.",
            evidence: .convention,
            source: "Bezodis et al. 2019 describes \"hips above the shoulders\" without a number"
        ),
        MetricSpec(
            id: .shoulderLead,
            label: "Shoulders over hands",
            // Lean of the wrist-to-shoulder line from vertical. Positive = shoulders ahead of hands.
            green: -5...15,
            yellow: -12...25,
            cueGood: "Shoulders are stacked over your hands.",
            cueLow: "Shoulders are behind your hands. Shift your weight forward.",
            cueHigh: "Shoulders are far past your hands. Ease back so you can hold \"set\" still.",
            evidence: .convention,
            source: "Bezodis et al. 2019 describes \"shoulders ahead of the start line\" without a number"
        ),
    ]

    static let clearance: [MetricSpec] = [
        MetricSpec(
            id: .pushKnee,
            label: "Push-leg extension",
            green: 150...180,
            yellow: 138...180,
            cueGood: "Push leg extends fully off the block.",
            cueLow: "Push leg is still bent as it leaves the block. Push all the way through the pedal.",
            cueHigh: "Push leg extends fully off the block.",
            evidence: .study,
            source: "ISBS 2008 block-phase kinematics study (front knee 149–169° at exit, 3 sprinters)"
        ),
        MetricSpec(
            id: .pushHip,
            label: "Hip extension",
            green: 160...180,
            yellow: 145...180,
            cueGood: "Hips are fully extended: shoulder, hip and knee are in line.",
            cueLow: "You are bent at the waist. Drive your hips forward as you push.",
            cueHigh: "Hips are fully extended: shoulder, hip and knee are in line.",
            evidence: .convention,
            source: "Bezodis et al. 2019 notes hip extension matters in the push phase, no exit angle given"
        ),
        MetricSpec(
            id: .driveAngle,
            label: "Drive angle",
            // Angle of the push-ankle-to-shoulder line above the ground.
            green: 35...50,
            yellow: 30...56,
            cueGood: "Good low drive angle out of the blocks.",
            cueLow: "Very low exit. Make sure you can get your first foot down under you.",
            cueHigh: "You are popping up. Stay low and push the track back behind you.",
            evidence: .convention,
            source: "Coaching guidance of a 40–45° exit angle"
        ),
        MetricSpec(
            id: .swingHip,
            label: "Knee drive",
            // Trunk-to-thigh angle of the swing (rear-block) leg. Smaller = knee driven further.
            green: 60...110,
            yellow: 50...125,
            cueGood: "Swing knee is driving forward well.",
            cueLow: "Swing knee is tucked very tight to the chest.",
            cueHigh: "Swing leg is trailing. Punch the rear knee forward as the front leg pushes.",
            evidence: .convention,
            source: "No published exit angle found; provisional range"
        ),
    ]
}

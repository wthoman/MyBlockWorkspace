// Video frame -> still image -> pose landmarks (Apple Vision, on device) -> graded checkpoints.

import AVFoundation
import UIKit
import Vision

enum FrameAnalyzer {
    /// Longest side of the extracted frame, in pixels.
    static let maxSide: CGFloat = 1280

    /// Exact (frame-accurate) still image from the video, upright.
    static func image(videoURL: URL, time: Double, maxSide: CGFloat = maxSide) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        let (cgImage, _) = try await generator.image(at: CMTime(seconds: max(0, time), preferredTimescale: 600))
        return cgImage
    }

    /// Detects the pose in one frame. Runs Vision off the main thread, on device.
    static func analyze(videoURL: URL, time: Double, kind: FrameKind, adjusted: Bool) async throws -> (RepFrame, UIImage) {
        let cgImage = try await image(videoURL: videoURL, time: time)
        let pose = try await detectPose(in: cgImage)
        let frame = RepFrame(kind: kind, time: time, width: Double(cgImage.width), height: Double(cgImage.height),
                             pose: pose, adjusted: adjusted)
        return (frame, UIImage(cgImage: cgImage))
    }

    static func detectPose(in image: CGImage) async throws -> Pose? {
        do {
            return try await Task.detached(priority: .userInitiated) {
                try PoseDetector.detect(in: image)
            }.value
        } catch let error as NSError where error.domain == VNErrorDomain && error.code == VNErrorCode.internalError.rawValue
                    && error.localizedDescription.contains("Unable to setup request") {
            // Vision can't load the body-pose model here (the Simulator never can).
            throw AnalysisError.poseDetectionUnavailable
        }
    }
}

enum AnalysisError: LocalizedError {
    case poseDetectionUnavailable
    var errorDescription: String? {
        switch self {
        case .poseDetectionUnavailable:
            "Pose detection isn't available on this device, so the frames can't be checked. Your video is saved; open it on an iPhone to analyse it."
        }
    }
}

enum PoseDetector {
    private static let visionNames: [Joint: VNHumanBodyPoseObservation.JointName] = [
        .nose: .nose, .neck: .neck,
        .leftShoulder: .leftShoulder, .rightShoulder: .rightShoulder,
        .leftElbow: .leftElbow, .rightElbow: .rightElbow,
        .leftWrist: .leftWrist, .rightWrist: .rightWrist,
        .root: .root,
        .leftHip: .leftHip, .rightHip: .rightHip,
        .leftKnee: .leftKnee, .rightKnee: .rightKnee,
        .leftAnkle: .leftAnkle, .rightAnkle: .rightAnkle,
    ]

    /// Detects the most clearly seen person in an upright image. Returns nil when nobody is found.
    static func detect(in image: CGImage) throws -> Pose? {
        let request = VNDetectHumanBodyPoseRequest()
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])

        let candidates: [[VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]] =
            (request.results ?? []).compactMap { try? $0.recognizedPoints(.all) }
        guard let best = candidates.max(by: { score($0) < score($1) }) else { return nil }

        var pose: Pose = [:]
        for (joint, name) in visionNames {
            guard let point = best[name], point.confidence > 0 else { continue }
            // Vision uses a bottom-left origin; flip to top-left like the image.
            pose[joint] = Landmark(x: point.location.x, y: 1 - point.location.y, confidence: Double(point.confidence))
        }
        return pose.isEmpty ? nil : pose
    }

    private static func score(_ points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]) -> Float {
        points.values.reduce(0) { $0 + $1.confidence }
    }
}

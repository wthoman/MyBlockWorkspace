// Camera capture and movie recording (video only, no microphone). All session work happens
// on a private serial queue.

import AVFoundation
import QuartzCore
import SwiftUI

/// Recording state is only touched on `queue` and UI state only on the main thread.
final class CameraController: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate, StartRecorder,
    @unchecked Sendable {
    enum CameraError: LocalizedError {
        case unavailable
        case notRecording
        var errorDescription: String? {
            switch self {
            case .unavailable: "Camera is not available"
            case .notRecording: "The recording was not saved"
            }
        }
    }

    let session = AVCaptureSession()
    @Published private(set) var isReady = false
    /// Set when the camera stops unexpectedly (interruption, error). The session screen
    /// turns this into an audible stop.
    @Published var problem: String?
    @Published private(set) var position: AVCaptureDevice.Position = .back

    private let output = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "myblock.camera")
    private var input: AVCaptureDeviceInput?
    private var observers: [NSObjectProtocol] = []

    // Rotation handling (main thread).
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    // Recording state (camera queue).
    private var startContinuation: CheckedContinuation<Double, Error>?
    private var finishContinuation: CheckedContinuation<URL, Error>?
    private var finishedResult: Result<URL, Error>?
    /// The file currently being recorded. Cleared once a finished file has been handed over,
    /// so a later cancel never deletes a recording that was already delivered.
    private var recordingURL: URL?
    private var stopRequested = false

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session,
                                            queue: .main) { [weak self] note in
            self?.problem = Self.describeInterruption(note)
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session,
                                            queue: .main) { [weak self] _ in
            self?.problem = "The camera stopped working."
            self?.start()
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private static func describeInterruption(_ note: Notification) -> String {
        guard let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
              let reason = AVCaptureSession.InterruptionReason(rawValue: raw) else {
            return "The camera was interrupted."
        }
        switch reason {
        case .videoDeviceNotAvailableInBackground: return "MyBlock left the screen, so the camera stopped."
        case .videoDeviceInUseByAnotherClient: return "Another app took over the camera."
        case .videoDeviceNotAvailableDueToSystemPressure: return "The iPhone got too hot to keep recording."
        default: return "The camera was interrupted."
        }
    }

    // MARK: Session

    func start() {
        queue.async {
            if self.input == nil { self.configure() }
            if !self.session.isRunning { self.session.startRunning() }
            let ready = self.input != nil && self.session.isRunning
            DispatchQueue.main.async {
                self.isReady = ready
                self.updateRotationCoordinator()
            }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func flip() {
        isReady = false
        queue.async {
            let next: AVCaptureDevice.Position = self.position == .back ? .front : .back
            self.configure(position: next)
            let ready = self.input != nil
            DispatchQueue.main.async {
                self.position = next
                self.isReady = ready
                self.updateRotationCoordinator()
            }
        }
    }

    private func configure(position: AVCaptureDevice.Position? = nil) {
        let position = position ?? .back
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if let input { session.removeInput(input) }
        input = nil

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let newInput = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(newInput) else { return }

        // 1080p at up to 60 fps where the camera supports it: twice the frames around
        // block clearance. Falls back to the standard 1080p preset.
        if let format = Self.bestFormat(for: device) {
            session.sessionPreset = .inputPriority
            session.addInput(newInput)
            if (try? device.lockForConfiguration()) != nil {
                device.activeFormat = format.format
                let duration = CMTime(value: 1, timescale: CMTimeScale(format.fps))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                device.unlockForConfiguration()
            }
        } else {
            session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
            session.addInput(newInput)
        }
        input = newInput

        if !session.outputs.contains(output), session.canAddOutput(output) {
            session.addOutput(output)
        }
    }

    private static func bestFormat(for device: AVCaptureDevice) -> (format: AVCaptureDevice.Format, fps: Int)? {
        var best: (format: AVCaptureDevice.Format, fps: Int)?
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width == 1920, dims.height == 1080 else { continue }
            let maxRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let fps = maxRate >= 60 ? 60 : (maxRate >= 30 ? 30 : 0)
            guard fps > 0 else { continue }
            if best == nil || fps > best!.fps { best = (format, fps) }
        }
        return best?.fps == 60 ? best : nil
    }

    // MARK: Rotation

    func attach(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        updateRotationCoordinator()
    }

    /// Keeps the preview level with the horizon whichever way the phone is held.
    private func updateRotationCoordinator() {
        rotationObservation = nil
        rotationCoordinator = nil
        guard let device = input?.device, let previewLayer else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) {
            [weak previewLayer] coordinator, _ in
            DispatchQueue.main.async {
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                if let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            }
        }
    }

    // MARK: Recording

    /// Starts recording and returns the host time (`CACurrentMediaTime`) when it began.
    func startRecording() async throws -> Double {
        let angle = await MainActor.run { rotationCoordinator?.videoRotationAngleForHorizonLevelCapture }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("start-\(UUID().uuidString)")
            .appendingPathExtension("mov")

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Double, Error>) in
                queue.async {
                    guard self.input != nil, self.session.isRunning, let connection = self.output.connection(with: .video) else {
                        continuation.resume(throwing: CameraError.unavailable)
                        return
                    }
                    if let angle, connection.isVideoRotationAngleSupported(angle) {
                        connection.videoRotationAngle = angle
                    }
                    self.finishedResult = nil
                    self.stopRequested = false
                    self.recordingURL = url
                    self.startContinuation = continuation
                    self.output.startRecording(to: url, recordingDelegate: self)
                }
            }
        } onCancel: {
            self.cancelRecording()
        }
    }

    /// Stops recording and returns the finished movie file.
    func stopRecording() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let result = self.finishedResult {
                    self.finishedResult = nil
                    self.recordingURL = nil
                    continuation.resume(with: result)
                } else if self.output.isRecording, self.finishContinuation == nil {
                    self.stopRequested = true
                    self.finishContinuation = continuation
                    self.output.stopRecording()
                } else {
                    continuation.resume(throwing: CameraError.notRecording)
                }
            }
        }
    }

    /// Stops any recording in progress, discards its file and fails pending waits with CancellationError.
    func cancelRecording() {
        queue.async {
            let url = self.recordingURL
            self.recordingURL = nil
            self.startContinuation?.resume(throwing: CancellationError())
            self.startContinuation = nil
            self.finishContinuation?.resume(throwing: CancellationError())
            self.finishContinuation = nil
            self.finishedResult = nil
            if self.output.isRecording { self.output.stopRecording() }
            if let url { try? FileManager.default.removeItem(at: url) }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        let startedAt = CACurrentMediaTime()
        queue.async {
            self.startContinuation?.resume(returning: startedAt)
            self.startContinuation = nil
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        queue.async {
            // A cancelled recording: its file was already discarded.
            guard self.recordingURL == outputFileURL else {
                try? FileManager.default.removeItem(at: outputFileURL)
                return
            }
            var result: Result<URL, Error> = .success(outputFileURL)
            if let error {
                // An interrupted recording can still be a playable file.
                let finished = (error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false
                if !finished { result = .failure(error) }
            }
            // Finished before it ever started: recording failed.
            if let start = self.startContinuation {
                self.startContinuation = nil
                self.recordingURL = nil
                try? FileManager.default.removeItem(at: outputFileURL)
                start.resume(throwing: error ?? CameraError.notRecording)
                return
            }
            if let finish = self.finishContinuation {
                self.finishContinuation = nil
                self.recordingURL = nil
                finish.resume(with: result)
            } else {
                // Stopped by itself (interruption, disk full). Keep the result for stopRecording().
                self.finishedResult = result
                if !self.stopRequested {
                    DispatchQueue.main.async { self.problem = self.problem ?? "The recording stopped unexpectedly." }
                }
            }
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let camera: CameraController

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = camera.session
        // Show the whole recorded frame so the athlete can check everything is in view.
        view.previewLayer.videoGravity = .resizeAspect
        camera.attach(previewLayer: view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

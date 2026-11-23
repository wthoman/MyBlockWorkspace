// The start screen: camera preview, one Start button, then large audio-led start states.
// The athlete is away from the phone once the countdown runs, so everything they need is
// heard; the screen only backs it up.

import AVFoundation
import SwiftUI

struct SessionView: View {
    let sessionID: UUID
    /// "Try again": start the countdown as soon as the camera is ready.
    let autoStart: Bool
    let onFinished: (UUID) -> Void
    let onExit: () -> Void

    @StateObject private var camera: CameraController
    @StateObject private var sequence: StartSequence
    @ObservedObject private var settingsStore = SettingsStore.shared
    @ObservedObject private var soundTest = SoundTest.shared
    @State private var auth = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var lastRepID: UUID?
    @State private var didAutoStart = false
    @State private var showGuide = false
    @State private var showSettings = false
    @State private var alert: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(sessionID: UUID, autoStart: Bool, onFinished: @escaping (UUID) -> Void, onExit: @escaping () -> Void) {
        self.sessionID = sessionID
        self.autoStart = autoStart
        self.onFinished = onFinished
        self.onExit = onExit
        let camera = CameraController()
        _camera = StateObject(wrappedValue: camera)
        _sequence = StateObject(wrappedValue: StartSequence(audio: CuePlayer.shared, recorder: camera))
    }

    private var settings: StartSettings { settingsStore.settings }

    var body: some View {
        Group {
            if auth == .authorized {
                cameraScreen
            } else {
                PermissionScreen(auth: $auth, onBack: onExit)
            }
        }
        // Keep the screen on while the camera screen is up so it can't lock mid-rep.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            sequence.cancel()
            camera.stop()
        }
    }

    // MARK: Camera screen

    private var cameraScreen: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(camera: camera).ignoresSafeArea()
                .accessibilityLabel("Camera preview")

            if settings.largeCues || !isActiveStage {
                StageOverlay(phase: sequence.phase, repIndex: sequence.repIndex, repTotal: sequence.repTotal)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: sequence.phase)
            } else {
                VStack {
                    CompactStage(phase: sequence.phase)
                    Spacer()
                }
                .padding(.top, 72)
            }

            VStack(spacing: Theme.Space.md) {
                topBar
                Spacer()
                bottomControls
            }
            .padding(.horizontal, Theme.Space.gutter).padding(.vertical, Theme.Space.md)
        }
        .onAppear { camera.start() }
        .sensoryFeedback(.start, trigger: sequence.isRunning) { _, running in running }
        .onChange(of: camera.isReady) { _, ready in
            if ready, autoStart, !didAutoStart {
                didAutoStart = true
                start()
            }
        }
        .onChange(of: camera.problem) { _, problem in
            guard let problem else { return }
            camera.problem = nil
            if sequence.isRunning { sequence.abort(reason: problem) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, sequence.isRunning {
                sequence.abort(reason: "MyBlock was closed during the start.")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began, sequence.isRunning else { return }
            sequence.abort(reason: "A call or alert interrupted the start commands.")
        }
        .sheet(isPresented: $showGuide) { SetupGuideSheet() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .alert("Can't start", isPresented: Binding(isPresent: $alert)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alert ?? "")
        }
    }

    /// True from the countdown until the rep is saved.
    private var isActiveStage: Bool { sequence.isRunning }

    private var topBar: some View {
        HStack(spacing: Theme.Space.sm) {
            if !sequence.isRunning {
                IconButton(systemName: "chevron.left", label: "Back", onDark: true, action: onExit)
                Spacer()
                IconButton(systemName: soundTest.isPlaying ? "speaker.wave.3.fill" : "speaker.wave.2.fill",
                           label: "Hear a start at the current volume", onDark: true) {
                    soundTest.play(startSound: settings.startSound)
                }
                .disabled(soundTest.isPlaying)
                IconButton(systemName: "questionmark", label: "How to set up the phone", onDark: true) { showGuide = true }
                IconButton(systemName: "slider.horizontal.3", label: "Start settings", onDark: true) { showSettings = true }
                IconButton(systemName: "arrow.triangle.2.circlepath.camera", label: "Switch camera", onDark: true) { camera.flip() }
            } else {
                Spacer()
            }
        }
    }

    @ViewBuilder private var bottomControls: some View {
        switch sequence.phase {
        case .idle:
            VStack(spacing: Theme.Space.md) {
                if camera.position == .front {
                    Text("Front camera. The rear camera gives a better view of your start.")
                        .font(Theme.Fonts.small)
                        .foregroundStyle(Theme.onDark)
                        .multilineTextAlignment(.center)
                }
                MBButton(label: camera.isReady ? "Start" : "Starting camera…",
                         disabled: !camera.isReady || soundTest.isPlaying) {
                    start()
                }
            }
            .frame(maxWidth: 480)
        case .complete:
            EmptyView()
        case .failed:
            VStack(spacing: Theme.Space.sm) {
                MBButton(label: "Try again") { start() }
                if let lastRepID {
                    MBButton(label: "Review saved rep", variant: .secondary) { onFinished(lastRepID) }
                }
                MBButton(label: "Back", variant: .ghost, action: onExit)
            }
            .frame(maxWidth: 480)
        case .saving:
            EmptyView()
        default:
            MBButton(label: "Cancel", variant: .secondary) { sequence.cancel() }
                .frame(maxWidth: 480)
                .accessibilityHint("Stops this start without saving it")
        }
    }

    private func start() {
        guard !sequence.isRunning else { return }
        guard RepStore.hasSpaceForRecording() else {
            alert = RepStore.StoreError.lowStorage.errorDescription
            return
        }
        guard camera.isReady else {
            alert = "The camera isn't ready yet."
            return
        }
        soundTest.stop()
        let sessionID = sessionID
        sequence.start(settings: settings, onRecorded: { recorded in
            let rep = try RepStore.shared.add(
                videoAt: recorded.url, sessionID: sessionID, origin: .recorded, gunTime: recorded.gunTime,
                gunTimeUncertainty: recorded.gunTimeUncertainty, holdSeconds: recorded.holdSeconds
            )
            lastRepID = rep.id
        }, onFinished: {
            guard let id = lastRepID else { return }
            // Let "Recording complete" show briefly, then the review is waiting when the athlete returns.
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                onFinished(id)
            }
        })
    }
}

// MARK: - Stage display

/// Full-screen start state in poster colors. The words carry the meaning; color supports it.
private struct StageOverlay: View {
    let phase: StartSequence.Phase
    let repIndex: Int
    let repTotal: Int

    var body: some View {
        GeometryReader { geo in
            let big = min(geo.size.width, geo.size.height) * 0.2
            ZStack {
                if let tint { tint.ignoresSafeArea() }
                VStack(spacing: Theme.Space.md) {
                    if repTotal > 1, phase != .idle {
                        Text("Rep \(repIndex) of \(repTotal)")
                            .font(Theme.Fonts.meta)
                            .foregroundStyle(ink.opacity(0.85))
                    }
                    content(big: big)
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var tint: Color? {
        switch phase {
        case .idle: nil
        case .preparing, .resting: Theme.Stage.ready
        case .marks: Theme.Stage.marks
        case .set: Theme.Stage.set
        case .go, .saving: Theme.Stage.go
        case .complete: Theme.Stage.done
        case .failed: Theme.Stage.failed
        }
    }

    /// Navy on the yellow "set" screen, white everywhere else.
    private var ink: Color { phase == .set ? Theme.navy : Theme.white }

    @ViewBuilder private func content(big: CGFloat) -> some View {
        switch phase {
        case .idle:
            EmptyView()
        case let .preparing(remaining):
            stageTitle("Get ready", size: big * 0.42)
            countdown(remaining, size: big * 1.6)
            caption("Walk to your blocks and listen")
        case let .resting(remaining):
            stageTitle("Rest", size: big * 0.42)
            countdown(remaining, size: big * 1.6)
            caption("The next rep starts by itself")
        case .marks:
            stageTitle("On your\nmarks", size: big * 0.62)
        case .set:
            stageTitle("Set", size: big * 1.2)
        case .go:
            stageTitle("Go", size: big * 1.4)
        case .saving:
            stageTitle("Go", size: big * 1.4)
            caption("Saving…")
        case .complete:
            Image(systemName: "checkmark")
                .font(.system(size: big * 0.4, weight: .heavy))
                .foregroundStyle(Theme.navy)
                .frame(width: big * 0.8, height: big * 0.8)
                .background(Circle().fill(Theme.white))
                .accessibilityHidden(true)
            stageTitle("Saved", size: big * 0.6)
            caption("Recording complete")
        case let .failed(message):
            Image(systemName: "xmark")
                .font(.system(size: big * 0.32, weight: .heavy))
                .foregroundStyle(Theme.white)
                .frame(width: big * 0.7, height: big * 0.7)
                .background(Circle().fill(Theme.red))
                .accessibilityHidden(true)
            stageTitle("Stopped", size: big * 0.5)
            Text(message)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
    }

    private func countdown(_ value: Int, size: CGFloat) -> some View {
        Text("\(value)")
            .font(Theme.Fonts.titleFixed(size))
            .monospacedDigit()
            .foregroundStyle(Theme.yellow)
            .contentTransition(.numericText(countsDown: true))
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(Theme.Fonts.heading).foregroundStyle(ink)
    }

    private func stageTitle(_ text: String, size: CGFloat) -> some View {
        Text(text)
            .font(Theme.Fonts.titleFixed(size))
            .foregroundStyle(ink)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.4)
            .accessibilityLabel(text.replacingOccurrences(of: "\n", with: " "))
    }
}

/// Small status strip used when big screen cues are turned off in settings.
private struct CompactStage: View {
    let phase: StartSequence.Phase

    var body: some View {
        if let text {
            Text(text)
                .font(Theme.Fonts.sectionTitle)
                .foregroundStyle(Theme.white)
                .padding(.horizontal, Theme.Space.lg)
                .padding(.vertical, Theme.Space.sm)
                .background(Theme.navy.opacity(0.88), in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
        }
    }

    private var text: String? {
        switch phase {
        case let .preparing(r): "Get ready · \(r)"
        case let .resting(r): "Rest · \(r)"
        case .marks: "On your marks"
        case .set: "Set"
        case .go: "Go"
        case .saving: "Saving…"
        default: nil
        }
    }
}

// MARK: - Permission

/// Explains camera access before asking for it, and routes to Settings if it was denied.
private struct PermissionScreen: View {
    @Binding var auth: AVAuthorizationStatus
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Image(systemName: "camera")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Theme.red)
                .accessibilityHidden(true)
            Text(auth == .notDetermined ? "Record your starts" : "Camera is off")
                .font(Theme.Fonts.screenTitle)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(auth == .notDetermined
                 ? "MyBlock films each start so it can check your set position and block clearance. Video only, no sound. Everything stays on this iPhone."
                 : "MyBlock needs the camera to record your starts. Turn on Camera for MyBlock in Settings.")
                .textStyle(.body)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Theme.Space.lg)
            if auth == .notDetermined {
                MBButton(label: "Continue") {
                    Task {
                        _ = await AVCaptureDevice.requestAccess(for: .video)
                        auth = AVCaptureDevice.authorizationStatus(for: .video)
                    }
                }
            } else {
                MBButton(label: "Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            MBButton(label: "Back", variant: .ghost, action: onBack)
        }
        .padding(Theme.Space.gutter)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            auth = AVCaptureDevice.authorizationStatus(for: .video)
        }
    }
}

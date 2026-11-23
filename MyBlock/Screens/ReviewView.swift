// Watch the rep back: play, slow motion, frame steps, skeleton overlay, and markers for the
// two graded frames. Analysis runs automatically on arrival; "Adjust frame" lets the athlete
// move a marker when the automatic pick is wrong, and the correction is saved with the rep.

import AVFoundation
import SwiftUI

@MainActor
final class ReviewModel: ObservableObject {
    /// "Set" is graded just before the start signal; the athlete has not reacted yet.
    static let setOffset = -0.1
    /// Typical time from the start signal to the front foot leaving the block.
    static let clearanceOffset = 0.45
    static let rates: [Float] = [1, 0.5, 0.25]

    let repID: UUID
    let player: AVPlayer
    private let store: RepStore
    private var timeObserver: Any?

    @Published private(set) var rep: Rep
    @Published private(set) var duration: Double = 0
    @Published private(set) var frameStep: Double = 1.0 / 30
    @Published private(set) var videoAspect: CGFloat = 16.0 / 9.0
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published var rate: Float = 1
    @Published var showSkeleton = true { didSet { refreshOverlay() } }
    /// Pose drawn over the paused frame.
    @Published private(set) var overlayPose: Pose?
    @Published private(set) var analyzing: String?
    @Published var adjusting: FrameKind?
    @Published var errorMessage: String?
    /// Bumped when a corrected frame is saved (drives a haptic).
    @Published private(set) var savedCount = 0

    private var overlayTask: Task<Void, Never>?
    private var overlayCache: [Int: Pose?] = [:]

    init(repID: UUID, store: RepStore? = nil) {
        let store = store ?? RepStore.shared
        self.repID = repID
        self.store = store
        let rep = store.rep(repID)!
        self.rep = rep
        let player = AVPlayer(url: store.videoURL(for: rep))
        player.isMuted = true
        player.actionAtItemEnd = .pause
        self.player = player
    }

    var videoURL: URL { store.videoURL(for: rep) }

    func load() async {
        guard duration == 0 else { return }
        let asset = AVURLAsset(url: videoURL)
        do {
            let d = try await asset.load(.duration).seconds
            guard d.isFinite, d > 0 else { throw CocoaError(.fileReadCorruptFile) }
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let fps = try await track.load(.nominalFrameRate)
                if fps > 0 { frameStep = 1 / Double(fps) }
                let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
                let r = CGRect(origin: .zero, size: size).applying(transform)
                if r.height > 0 { videoAspect = abs(r.width / r.height) }
            }
            duration = d
        } catch {
            errorMessage = "Could not open this video. \(error.localizedDescription)"
            return
        }
        observeTime()
        seek(to: rep.frames[.set]?.time ?? autoTime(.set))
        await analyzeMissing()
    }

    private func observeTime() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) {
            [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds
                let playing = self.player.rate != 0
                if playing != self.isPlaying {
                    self.isPlaying = playing
                    self.refreshOverlay()
                }
            }
        }
    }

    func tearDown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        overlayTask?.cancel()
    }

    /// Automatic frame estimate: from the start signal for recorded reps, or a guess in the
    /// middle of an imported clip (which the athlete is prompted to check).
    func autoTime(_ kind: FrameKind) -> Double {
        let clamp = { (t: Double) in min(max(0, self.duration - 0.01), max(0, t)) }
        if let gun = rep.gunTime {
            return clamp(gun + (kind == .set ? Self.setOffset : Self.clearanceOffset))
        }
        return clamp(duration * (kind == .set ? 0.4 : 0.5))
    }

    // MARK: Playback

    func togglePlay() {
        if isPlaying {
            player.pause()
        } else {
            if currentTime >= duration - frameStep { seek(to: 0) }
            player.playImmediately(atRate: rate)
        }
    }

    func cycleRate() {
        let i = Self.rates.firstIndex(of: rate) ?? 0
        rate = Self.rates[(i + 1) % Self.rates.count]
        if isPlaying { player.rate = rate }
    }

    func step(_ frames: Int) {
        player.pause()
        seek(to: currentTime + Double(frames) * frameStep)
    }

    func seek(to t: Double) {
        let clamped = min(max(0, duration), max(0, t))
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) {
            [weak self] _ in
            Task { @MainActor in self?.refreshOverlay() }
        }
    }

    // MARK: Skeleton overlay

    /// Shows the stored pose on a graded frame, or detects one for any other paused frame.
    private func refreshOverlay() {
        overlayTask?.cancel()
        guard showSkeleton, !isPlaying, duration > 0 else {
            overlayPose = nil
            return
        }
        let t = currentTime
        if let stored = FrameKind.allCases.compactMap({ rep.frames[$0] }).first(where: { abs($0.time - t) < frameStep / 2 }) {
            overlayPose = stored.pose
            return
        }
        let key = Int((t / frameStep).rounded())
        if let cached = overlayCache[key] {
            overlayPose = cached
            return
        }
        overlayPose = nil
        let url = videoURL
        overlayTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled,
                  let image = try? await FrameAnalyzer.image(videoURL: url, time: t, maxSide: 720),
                  !Task.isCancelled else { return }
            let pose = (try? await FrameAnalyzer.detectPose(in: image)) ?? nil
            guard !Task.isCancelled else { return }
            overlayCache[key] = pose
            overlayPose = pose
        }
    }

    // MARK: Analysis

    private func analyzeMissing() async {
        let missing = FrameKind.allCases.filter { rep.frames[$0] == nil }
        guard !missing.isEmpty else { return }
        for kind in missing {
            analyzing = "Checking \(kind.title.lowercased())…"
            do {
                let (frame, _) = try await FrameAnalyzer.analyze(videoURL: videoURL, time: autoTime(kind), kind: kind, adjusted: false)
                rep.frames[kind] = frame
            } catch {
                errorMessage = (error as? AnalysisError)?.errorDescription ?? "Analysis failed. \(error.localizedDescription)"
                break
            }
        }
        analyzing = nil
        save()
        refreshOverlay()
    }

    func beginAdjust(_ kind: FrameKind) {
        player.pause()
        adjusting = kind
        seek(to: rep.frames[kind]?.time ?? autoTime(kind))
    }

    /// Re-analyses the chosen kind at the current frame and keeps the correction.
    func useCurrentFrame() async {
        savedCount += 1
        guard let kind = adjusting else { return }
        await reanalyze(kind, at: currentTime, adjusted: true)
        adjusting = nil
    }

    func resetToAutomatic() async {
        guard let kind = adjusting else { return }
        await reanalyze(kind, at: autoTime(kind), adjusted: false)
        adjusting = nil
    }

    private func reanalyze(_ kind: FrameKind, at time: Double, adjusted: Bool) async {
        analyzing = "Checking \(kind.title.lowercased())…"
        defer { analyzing = nil }
        do {
            let (frame, _) = try await FrameAnalyzer.analyze(videoURL: videoURL, time: time, kind: kind, adjusted: adjusted)
            rep.frames[kind] = frame
            save()
            seek(to: time)
        } catch {
            errorMessage = (error as? AnalysisError)?.errorDescription ?? "Analysis failed. \(error.localizedDescription)"
        }
    }

    private func save() {
        do {
            try store.update(rep)
        } catch {
            errorMessage = "Couldn't save the analysis. \(error.localizedDescription)"
        }
    }
}

struct ReviewView: View {
    let onResults: (UUID) -> Void
    let onTryAgain: (UUID) -> Void
    let onHome: () -> Void
    @StateObject private var model: ReviewModel

    init(repID: UUID, onResults: @escaping (UUID) -> Void, onTryAgain: @escaping (UUID) -> Void,
         onHome: @escaping () -> Void) {
        self.onResults = onResults
        self.onTryAgain = onTryAgain
        self.onHome = onHome
        _model = StateObject(wrappedValue: ReviewModel(repID: repID))
    }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let layout = landscape ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                video(maxVideoHeight: landscape ? geo.size.height : min(geo.size.width / model.videoAspect, geo.size.height * 0.5))
                    .frame(maxWidth: .infinity, maxHeight: landscape ? .infinity : nil)
                ScrollView {
                    controls
                        .padding(.horizontal, Theme.Space.gutter)
                        .padding(.top, Theme.Space.lg)
                        .padding(.bottom, Theme.Space.xxl)
                }
                .frame(width: landscape ? 380 : nil)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .sensoryFeedback(.success, trigger: model.savedCount)
        .task { await model.load() }
        .onDisappear { model.tearDown() }
        .alert("Something went wrong", isPresented: Binding(isPresent: $model.errorMessage)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: Video

    private func video(maxVideoHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                IconButton(systemName: "chevron.left", label: "Home", action: onHome)
                Spacer()
                Text(model.rep.date.repLabel).font(Theme.Fonts.smallBold).foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.vertical, Theme.Space.sm)

            ZStack {
                Theme.navy
                ZStack {
                    PlayerView(player: model.player)
                    if let pose = model.overlayPose, model.showSkeleton, !model.isPlaying {
                        SkeletonOverlay(pose: pose, metrics: metricsForOverlay)
                            .allowsHitTesting(false)
                    }
                }
                .aspectRatio(model.videoAspect, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement()
                .accessibilityLabel("Video of your start")
                .accessibilityValue(String(format: "%.2f seconds", model.currentTime))
            }
            .frame(height: maxVideoHeight)
        }
    }

    /// Grade dots only on the graded frames themselves.
    private var metricsForOverlay: [MetricResult] {
        FrameKind.allCases.compactMap { model.rep.frames[$0] }
            .first { abs($0.time - model.currentTime) < model.frameStep / 2 }?.metrics ?? []
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Timeline(model: model)

            HStack(spacing: Theme.Space.sm) {
                transportKey(model.isPlaying ? "pause.fill" : "play.fill", label: model.isPlaying ? "Pause" : "Play",
                             wide: true) {
                    model.togglePlay()
                }
                transportKey("backward.frame.fill", label: "Previous frame") { model.step(-1) }
                transportKey("forward.frame.fill", label: "Next frame") { model.step(1) }
                transportKey(nil, text: rateLabel, label: "Playback speed \(rateLabel)", active: model.rate != 1) {
                    model.cycleRate()
                }
                .accessibilityHint("Switches between normal, half and quarter speed")
                transportKey("figure.stand", label: model.showSkeleton ? "Hide skeleton" : "Show skeleton",
                             active: model.showSkeleton) {
                    model.showSkeleton.toggle()
                }
            }

            if let kind = model.adjusting {
                adjustPanel(kind)
            } else {
                markers
                if let busy = model.analyzing {
                    HStack(spacing: Theme.Space.md) {
                        ProgressView().tint(Theme.red)
                        Text(busy).textStyle(.body)
                    }
                    .frame(maxWidth: .infinity)
                }
                VStack(spacing: Theme.Space.sm) {
                    MBButton(label: "See results", disabled: !model.rep.isAnalyzed || model.analyzing != nil) {
                        onResults(model.repID)
                    }
                    MBButton(label: "Try again", variant: .secondary, arrow: "arrow.counterclockwise") {
                        onTryAgain(model.rep.sessionID)
                    }
                }
            }
        }
    }

    private var rateLabel: String {
        switch model.rate {
        case 0.5: "½×"
        case 0.25: "¼×"
        default: "1×"
        }
    }

    /// The two graded frames, each a row you can jump to or adjust.
    private var markers: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Checked frames").font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.text)
                .padding(.bottom, Theme.Space.sm)
            Rule(color: Theme.navy)
            if model.rep.source == .imported {
                Text("Imported clip: these frames are a first guess. Check them with Adjust.")
                    .textStyle(.small)
                    .padding(.bottom, Theme.Space.sm)
            }
            ForEach(FrameKind.allCases) { kind in
                HStack(spacing: Theme.Space.md) {
                    Button { model.seek(to: model.rep.frames[kind]?.time ?? model.autoTime(kind)) } label: {
                        HStack(spacing: Theme.Space.md) {
                            MarkerGlyph(kind: kind, size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: Theme.Space.xs) {
                                    Text(kind.title).font(Theme.Fonts.heading).foregroundStyle(Theme.text)
                                    if model.rep.frames[kind]?.adjusted == true {
                                        Text("· picked by you").font(Theme.Fonts.small).foregroundStyle(Theme.textMuted)
                                    }
                                }
                                if let text = markerTime(kind) {
                                    Text(text).textStyle(.small).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressFade())
                    .accessibilityHint("Jumps to this frame")
                    Button("Adjust") { model.beginAdjust(kind) }
                        .font(Theme.Fonts.button)
                        .foregroundStyle(Theme.red)
                        .frame(minWidth: Theme.minTouch, minHeight: Theme.minTouch)
                        .disabled(model.analyzing != nil || model.duration == 0)
                        .accessibilityLabel("Adjust \(kind.title.lowercased()) frame")
                }
                .padding(.vertical, Theme.Space.xs)
                .overlay(alignment: .bottom) { Rule() }
            }
        }
    }

    private func markerTime(_ kind: FrameKind) -> String? {
        guard let t = model.rep.frames[kind]?.time else { return nil }
        return Coaching.relativeTimeText(time: t, gunTime: model.rep.gunTime, uncertainty: model.rep.gunTimeUncertainty)
            ?? String(format: "%.2f s into the clip", t)
    }

    private func adjustPanel(_ kind: FrameKind) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.md) {
                MarkerGlyph(kind: kind, size: 30)
                Text("Adjust \(kind.title.lowercased())").font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.text)
            }
            Text(kind == .set
                 ? "Step to the last still frame in set, just before you move."
                 : "Step to the frame where your front foot leaves the block.")
                .textStyle(.body)
                .fixedSize(horizontal: false, vertical: true)
            Text(Coaching.relativeTimeText(time: model.currentTime, gunTime: model.rep.gunTime,
                                           uncertainty: model.rep.gunTimeUncertainty)
                 ?? String(format: "%.2f s into the clip", model.currentTime))
                .font(Theme.Fonts.smallBold.monospacedDigit())
                .foregroundStyle(Theme.textMuted)
            MBButton(label: model.analyzing ?? "Use this frame", disabled: model.analyzing != nil) {
                Task { await model.useCurrentFrame() }
            }
            HStack(spacing: Theme.Space.sm) {
                if model.rep.frames[kind]?.adjusted == true {
                    MBButton(label: "Back to automatic", variant: .ghost, fill: false, compact: true, arrow: nil) {
                        Task { await model.resetToAutomatic() }
                    }
                }
                MBButton(label: "Cancel", variant: .ghost, fill: false, compact: true, arrow: nil) { model.adjusting = nil }
            }
        }
        .padding(.top, Theme.Space.md)
        .overlay(alignment: .top) { Rule(color: Theme.navy) }
    }

    /// Transport control: plain glyph; play is a solid navy disc, active toggles turn red.
    private func transportKey(_ icon: String?, text: String? = nil, label: String, active: Bool = false, wide: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let icon {
                    Image(systemName: icon).font(.system(size: wide ? 20 : 19, weight: .semibold))
                } else {
                    Text(text ?? "").font(Theme.Fonts.roboto(.bold, 17, relativeTo: .body)).monospacedDigit()
                }
            }
            .foregroundStyle(wide ? Theme.white : (active ? Theme.red : Theme.navy))
            .frame(width: wide ? 56 : nil, height: wide ? 56 : Theme.minTouch)
            .frame(maxWidth: wide ? nil : .infinity)
            .background { if wide { Circle().fill(Theme.navy) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressFade())
        .accessibilityLabel(label)
    }
}

/// Scrubber with the playhead, the estimated start signal, and the two graded frames.
private struct Timeline: View {
    @ObservedObject var model: ReviewModel

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let d = max(model.duration, 0.01)
            let x: (Double) -> CGFloat = { t in CGFloat(min(1, max(0, t / d))) * w }
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.hairline).frame(height: 4)
                Rectangle().fill(Theme.navy).frame(width: max(0, x(model.currentTime)), height: 4)
                if let gun = model.rep.gunTime {
                    Rectangle().fill(Theme.navy).frame(width: 2, height: 26).offset(x: x(gun) - 1)
                    Text("Start").font(Theme.Fonts.roboto(.medium, 11, relativeTo: .caption2)).foregroundStyle(Theme.textMuted)
                        .fixedSize().offset(x: x(gun) - 13, y: 22)
                }
                ForEach(FrameKind.allCases) { kind in
                    if let t = model.adjusting == kind ? model.currentTime : model.rep.frames[kind]?.time {
                        MarkerGlyph(kind: kind, size: 20).offset(x: x(t) - 10, y: -20)
                    }
                }
                Circle().fill(Theme.navy).frame(width: 16, height: 16)
                    .offset(x: x(model.currentTime) - 8)
            }
            .frame(height: 56)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                model.player.pause()
                model.seek(to: Double(value.location.x / max(w, 1)) * d)
            })
        }
        .frame(height: 56)
        .padding(.top, Theme.Space.md)
        .accessibilityElement()
        .accessibilityLabel("Timeline")
        .accessibilityValue(String(format: "%.2f of %.1f seconds", model.currentTime, model.duration))
        .accessibilityAdjustableAction { direction in
            model.step(direction == .increment ? 1 : -1)
        }
    }
}

/// Letter badges (S, C) for the two graded frames, so they never rely on color alone.
struct MarkerGlyph: View {
    let kind: FrameKind
    var size: CGFloat = 22
    var body: some View {
        LaneBadge(text: kind == .set ? "S" : "C", size: size, fill: kind == .set ? Theme.red : Theme.sky)
    }
}

struct PlayerView: UIViewRepresentable {
    let player: AVPlayer

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {}
}

/// The detected skeleton, plus grade dots when `metrics` is given. Sized to the video frame.
struct SkeletonOverlay: View {
    let pose: Pose
    var metrics: [MetricResult] = []

    var body: some View {
        Canvas { context, size in
            let stroke = max(2, max(size.width, size.height) / 260)
            let minC = Scoring.minConfidence
            func point(_ l: Landmark) -> CGPoint { CGPoint(x: l.x * size.width, y: l.y * size.height) }

            var bones = Path()
            for (a, b) in Analysis.skeleton {
                guard let p = pose[a], let q = pose[b], p.confidence >= minC, q.confidence >= minC else { continue }
                bones.move(to: point(p))
                bones.addLine(to: point(q))
            }
            context.stroke(bones, with: .color(.black.opacity(0.5)), style: StrokeStyle(lineWidth: stroke * 2, lineCap: .round))
            context.stroke(bones, with: .color(.white.opacity(0.95)), style: StrokeStyle(lineWidth: stroke, lineCap: .round))

            for metric in metrics where metric.value != nil {
                guard let l = pose[metric.anchor] else { continue }
                let r = stroke * 3
                let c = point(l)
                let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                context.fill(dot, with: .color(metric.grade.color))
                context.stroke(dot, with: .color(.black), lineWidth: stroke / 2)
            }
        }
        .accessibilityHidden(true)
    }
}

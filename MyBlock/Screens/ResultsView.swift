// Results lead with one cue for the next rep, then set position and clearance separately,
// then the measurements behind them. Only what the video actually measured is shown.

import SwiftUI

struct ResultsView: View {
    let repID: UUID
    let onReview: () -> Void
    let onTryAgain: (UUID) -> Void
    let onHome: () -> Void

    @ObservedObject private var store = RepStore.shared
    @State private var active: FrameKind = .set
    @State private var images: [FrameKind: UIImage] = [:]
    @State private var note = ""
    @State private var confirmDelete = false
    @State private var showAbout = false
    @FocusState private var noteFocused: Bool

    var body: some View {
        if let rep = store.rep(repID) {
            content(rep)
        } else {
            Color.clear.onAppear(perform: onHome)
        }
    }

    private func content(_ rep: Rep) -> some View {
        let setMetrics = rep.frames[.set]?.metrics
        let clearanceMetrics = rep.frames[.clearance]?.metrics
        let cue = Coaching.mainCue(set: setMetrics, clearance: clearanceMetrics)

        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                HStack {
                    IconButton(systemName: "chevron.left", label: "Back to video", action: onReview)
                    Spacer()
                    Text(rep.date.repLabel).font(Theme.Fonts.smallBold).foregroundStyle(Theme.textMuted)
                }

                // One thing to work on: a flat yellow block.
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text("Next rep").font(Theme.Fonts.meta).foregroundStyle(Theme.navy.opacity(0.75))
                    Text(cue.text)
                        .font(Theme.Fonts.cue)
                        .foregroundStyle(Theme.navy)
                        .fixedSize(horizontal: false, vertical: true)
                    if let kind = cue.kind {
                        Text("From your \(kind.title.lowercased())").font(Theme.Fonts.small).foregroundStyle(Theme.navy.opacity(0.75))
                    }
                }
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.vertical, Theme.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.yellow.overlay { PrintGrain(opacity: 0.05) })
                .padding(.horizontal, -Theme.Space.gutter)
                .accessibilityElement(children: .combine)

                // Set position and clearance, separately.
                HStack(spacing: 0) {
                    ForEach(FrameKind.allCases) { kind in
                        SummaryTile(kind: kind, metrics: rep.frames[kind]?.metrics ?? [], selected: active == kind) {
                            active = kind
                        }
                        if kind == .set { Rectangle().fill(Theme.navy.opacity(0.15)).frame(width: 1) }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.top, Theme.Space.lg)
                .background(Theme.cream.overlay { PrintGrain(opacity: 0.05) })
                .padding(.horizontal, -Theme.Space.gutter)
                .padding(.top, -Theme.Space.xl)

                frameDetail(rep, kind: active)

                aboutSection(rep)

                noteField(rep)

                VStack(spacing: Theme.Space.sm) {
                    MBButton(label: "Try again", arrow: "arrow.counterclockwise") { onTryAgain(rep.sessionID) }
                    MBButton(label: "Back to video", variant: .secondary, action: onReview)
                    VStack(alignment: .leading, spacing: 0) {
                        ShareLink(item: store.videoURL(for: rep)) {
                            ButtonLabel(label: "Share the original video", variant: .ghost, compact: true, arrow: "square.and.arrow.up")
                        }
                        .buttonStyle(PressStyle())
                        Rule()
                        MBButton(label: "Delete this rep", variant: .ghost, compact: true, arrow: "trash") { confirmDelete = true }
                        Rule()
                        MBButton(label: "Home", variant: .ghost, compact: true, action: onHome)
                    }
                    .padding(.top, Theme.Space.sm)
                    Text("Shared videos are the original recording, without the skeleton or results.")
                        .textStyle(.small)
                }
            }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.top, Theme.Space.sm)
            .padding(.bottom, Theme.Space.xxl)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background)
        .task(id: rep.frames.map { "\($0.key.rawValue)\($0.value.time)" }.sorted().joined()) { await loadImages(rep) }
        .onAppear { note = rep.note }
        .confirmationDialog("Delete this rep?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.delete(rep.id)
                onHome()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The video, note and results will be removed from this iPhone.")
        }
    }

    // MARK: Frame detail

    @ViewBuilder private func frameDetail(_ rep: Rep, kind: FrameKind) -> some View {
        if let frame = rep.frames[kind] {
            let metrics = frame.metrics
            let summary = FrameSummary(metrics: metrics)
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                ZStack {
                    if let image = images[kind] {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                            .overlay {
                                if let pose = frame.pose { SkeletonOverlay(pose: pose, metrics: metrics) }
                            }
                    } else {
                        Theme.surface.aspectRatio(16 / 9, contentMode: .fit)
                        ProgressView().tint(Theme.accent)
                    }
                }
                .background(Theme.navy)
                .accessibilityLabel("\(kind.title) frame with detected skeleton")

                if let timing = Coaching.relativeTimeText(time: frame.time, gunTime: rep.gunTime, uncertainty: rep.gunTimeUncertainty) {
                    Text((frame.adjusted ? "Picked by you · " : "Picked automatically · ") + timing.prefix(1).lowercased() + timing.dropFirst())
                        .textStyle(.small)
                } else if frame.adjusted {
                    Text("Frame picked by you").textStyle(.small)
                }
                if let note = summary.confidenceNote {
                    Label(note, systemImage: "eye.slash").textStyle(.small)
                }

                Text("Measurements").font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.text)
                    .padding(.top, Theme.Space.md)
                VStack(spacing: 0) {
                    Rule(color: Theme.navy)
                    ForEach(metrics) { metric in
                        MetricRow(metric: metric)
                        Rule()
                    }
                }
            }
        } else {
            Text("This rep hasn't been analysed yet. Go back to the video to run the check.")
                .textStyle(.body)
        }
    }

    // MARK: About

    private func aboutSection(_ rep: Rep) -> some View {
        DisclosureGroup(isExpanded: $showAbout) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("Guide ranges are typical values from sprint research and coaching. Good starters vary, so treat them as a guide for your setup rather than one ideal position.")
                Text("Angles come from one frame of a side-on video. A tilted phone, or one not square to the lane, shifts them. Vision doesn't see heels or toes, so foot position isn't measured.")
                Text("Measurements that couldn't be taken show \"Unable to assess\" and don't count against you.")
                if rep.gunTime != nil {
                    Text("Times relative to the start are estimated from the phone's clocks (±\(String(format: "%.2f", rep.gunTimeUncertainty ?? 0.05)) s). They aren't a reaction time or a false-start call.")
                }
            }
            .textStyle(.small)
            .padding(.top, Theme.Space.sm)
        } label: {
            Text("About these results").font(Theme.Fonts.heading).foregroundStyle(Theme.text)
        }
        .tint(Theme.navy)
    }

    // MARK: Note

    private func noteField(_ rep: Rep) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Note").font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.text)
            TextField("Add a short note (blocks, wind, how it felt)", text: $note, axis: .vertical)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.text)
                .lineLimit(1...3)
                .focused($noteFocused)
                .submitLabel(.done)
                .padding(Theme.Space.md)
                .background(Theme.tint, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                .onChange(of: note) { _, value in
                    if value.count > 140 { note = String(value.prefix(140)) }
                    if value.contains("\n") {
                        note = value.replacingOccurrences(of: "\n", with: "")
                        noteFocused = false
                    }
                }
                .onChange(of: noteFocused) { _, focused in
                    if !focused { saveNote(rep) }
                }
                .onDisappear { saveNote(rep) }
        }
    }

    private func saveNote(_ rep: Rep) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var current = store.rep(rep.id), current.note != trimmed else { return }
        current.note = trimmed
        try? store.update(current)
    }

    private func loadImages(_ rep: Rep) async {
        let url = store.videoURL(for: rep)
        for (kind, frame) in rep.frames {
            if let image = try? await FrameAnalyzer.image(videoURL: url, time: frame.time) {
                images[kind] = UIImage(cgImage: image)
            }
        }
    }
}

/// One of the two scores, set as a big numeral. The chosen one gets a red bar.
private struct SummaryTile: View {
    let kind: FrameKind
    let metrics: [MetricResult]
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let summary = FrameSummary(metrics: metrics)
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.sm) {
                    Circle().fill(kind == .set ? Theme.red : Theme.sky).frame(width: 8, height: 8)
                    Text(kind.title).font(Theme.Fonts.meta).foregroundStyle(Theme.textMuted)
                }
                if summary.canAssess {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(summary.inRange)").font(Theme.Fonts.bigNumber)
                        Text("/\(summary.assessed)").font(Theme.Fonts.number).foregroundStyle(Theme.textMuted)
                    }
                    .foregroundStyle(Theme.text)
                    Text("in guide range").textStyle(.small)
                } else {
                    Text("Unable to assess").font(Theme.Fonts.heading).foregroundStyle(Theme.text)
                        .padding(.vertical, Theme.Space.md)
                }
                Rectangle().fill(selected ? Theme.red : .clear).frame(height: 3).padding(.top, Theme.Space.sm)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, kind == .set ? 0 : Theme.Space.lg)
            .padding(.trailing, kind == .set ? Theme.Space.lg : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressFade())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind.title): \(summary.headline)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct MetricRow: View {
    let metric: MetricResult

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: icon)
                .foregroundStyle(metric.grade.color)
                .font(.system(size: 20, weight: .bold))
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(metric.label).font(Theme.Fonts.heading).foregroundStyle(Theme.text)
                    Spacer()
                    if let value = metric.value {
                        Text("\(value)°").font(Theme.Fonts.number).foregroundStyle(Theme.text).monospacedDigit()
                    } else {
                        Text("Unable to assess").font(Theme.Fonts.smallBold).foregroundStyle(Theme.textMuted)
                    }
                }
                Text("Guide \(metric.target)").font(Theme.Fonts.smallBold).foregroundStyle(Theme.textMuted)
                Text(metric.cue).textStyle(.body).padding(.top, Theme.Space.xs)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(metric.label), \(metric.value.map { "\($0) degrees" } ?? "unable to assess"), \(gradeWord). Guide \(metric.target). \(metric.cue)")
    }

    /// Shape differs by grade so the result doesn't rely on color alone.
    private var icon: String {
        switch metric.grade {
        case .green: "checkmark.circle.fill"
        case .yellow: "minus.circle.fill"
        case .red: "exclamationmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private var gradeWord: String {
        switch metric.grade {
        case .green: "in guide range"
        case .yellow: "near guide range"
        case .red: "outside guide range"
        case .unknown: "not measured"
        }
    }
}

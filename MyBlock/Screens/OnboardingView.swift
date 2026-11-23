// First-run intro (three short pages, skippable) and the same placement guide on demand.
// Nothing here is required: no account, no calibration, no checklist.

import SwiftUI

private struct GuidePage: Identifiable {
    let id: Int
    let title: String
    let text: String
}

private let guidePages = [
    GuidePage(id: 0, title: "Phone beside the lane",
              text: "Prop or mount it securely about 3–5 m to the side of your blocks, at roughly hip height."),
    GuidePage(id: 1, title: "Rear camera, side-on",
              text: "Keep the phone level and square to the lane, with your whole body, the blocks and your first steps in view."),
    GuidePage(id: 2, title: "Tap Start and listen",
              text: "Walk to your blocks during the countdown. Two rising notes: into your blocks. One note: set. Then the gun. Recording stops by itself and a chime confirms it's saved."),
]

/// Shown once, the first time the app opens.
struct OnboardingView: View {
    let onDone: () -> Void
    @State private var page = 0
    @ObservedObject private var soundTest = SoundTest.shared
    @ObservedObject private var settingsStore = SettingsStore.shared

    /// Each page is its own poster: sky, sun yellow, then navy.
    private static let fields: [Color] = [Theme.sky, Theme.yellow, Theme.navy]
    private var field: Color { Self.fields[page] }
    private var ink: Color { page == 2 ? Theme.white : Theme.navy }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("MyBlock").font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.text)
                Spacer()
                Button("Skip", action: onDone)
                    .font(Theme.Fonts.button)
                    .foregroundStyle(Theme.textMuted)
                    .frame(minWidth: Theme.minTouch, minHeight: Theme.minTouch)
            }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.bottom, Theme.Space.sm)
            .background(Theme.background.ignoresSafeArea(edges: .top))

            VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(guidePages) { p in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            PlacementDiagram(highlight: p.id)
                                .frame(height: 320)
                            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                                let pageInk = p.id == 2 ? Theme.white : Theme.navy
                                Text("\(p.id + 1) of \(guidePages.count)")
                                    .font(Theme.Fonts.meta)
                                    .foregroundStyle(pageInk.opacity(0.7))
                                Text(p.title)
                                    .font(Theme.Fonts.screenTitle)
                                    .foregroundStyle(pageInk)
                                    .minimumScaleFactor(0.6)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(p.text)
                                    .font(Theme.Fonts.body)
                                    .foregroundStyle(pageInk.opacity(0.85))
                                    .fixedSize(horizontal: false, vertical: true)
                                if p.id == guidePages.count - 1 {
                                    Button { soundTest.play(startSound: settingsStore.settings.startSound) } label: {
                                        ButtonLabel(label: soundTest.isPlaying ? "Playing…" : "Hear a start", variant: .ghost,
                                                    fill: false, compact: true, arrow: "speaker.wave.2", ghostColor: Theme.yellow)
                                    }
                                    .buttonStyle(PressStyle())
                                    .disabled(soundTest.isPlaying)
                                }
                            }
                            .padding(.horizontal, Theme.Space.gutter)
                            .padding(.top, Theme.Space.xl)
                        }
                        .frame(maxWidth: 600)
                        .frame(maxWidth: .infinity)
                    }
                    .tag(p.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: Theme.Space.sm) {
                ForEach(guidePages) { p in
                    Rectangle()
                        .fill(p.id <= page ? ink : ink.opacity(0.25))
                        .frame(height: 3)
                }
            }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.bottom, Theme.Space.lg)
            .accessibilityElement()
            .accessibilityLabel("Page \(page + 1) of \(guidePages.count)")

            MBButton(label: page < guidePages.count - 1 ? "Next" : "Start training") {
                if page < guidePages.count - 1 {
                    withAnimation { page += 1 }
                } else {
                    onDone()
                }
            }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.bottom, Theme.Space.lg)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
            }
            .background(field.overlay { PrintGrain(opacity: 0.06, light: page == 2) }.ignoresSafeArea(edges: .bottom))
            .animation(.easeInOut(duration: 0.25), value: page)
        }
        .padding(.top, Theme.Space.sm)
        .background(Theme.background.ignoresSafeArea())
    }
}

/// The placement guide on demand, from the "?" on the camera screen or Home.
struct SetupGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var soundTest = SoundTest.shared
    @ObservedObject private var settingsStore = SettingsStore.shared

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Setting up") { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    PlacementDiagram(highlight: nil).frame(height: 250)
                        .padding(.horizontal, -Theme.Space.gutter)
                    ForEach(guidePages) { p in
                        VStack(alignment: .leading, spacing: 0) {
                            Rule(color: p.id == 0 ? Theme.navy : Theme.hairline)
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.lg) {
                                LaneBadge(text: "\(p.id + 1)", size: 28, fill: Theme.accents[p.id % Theme.accents.count])
                                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
                                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                    Text(p.title).textStyle(.heading)
                                    Text(p.text).textStyle(.body).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.vertical, Theme.Space.md)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Text("Turn your volume up before you walk away. A call or alert can still interrupt a start; if it does, MyBlock stops and plays three falling notes.")
                        .textStyle(.small)
                        .fixedSize(horizontal: false, vertical: true)
                    MBButton(label: soundTest.isPlaying ? "Playing…" : "Hear a start", variant: .secondary,
                             compact: true, arrow: "speaker.wave.2", disabled: soundTest.isPlaying) {
                        soundTest.play(startSound: settingsStore.settings.startSound)
                    }
                }
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.bottom, Theme.Space.xxl)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationBackground(Theme.background)
    }
}

// Settings: ruled sections with one row rhythm. Every value has a working default; nothing
// here is needed to start.

import SwiftUI

struct SettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var reps = RepStore.shared
    @ObservedObject private var soundTest = SoundTest.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDeleteAll = false
    @State private var storageText = ""

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Settings") { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    section("Countdown") {
                        StepperRow(label: "Get ready", hint: "Time to walk to your blocks",
                                   value: $store.settings.prepSeconds, step: 5,
                                   min: StartSettings.prepRange.lowerBound, max: StartSettings.prepRange.upperBound)
                        Rule()
                        StepperRow(label: "In the blocks", hint: "Marks tone to set tone",
                                   value: $store.settings.marksSeconds, step: 1,
                                   min: StartSettings.marksRange.lowerBound, max: StartSettings.marksRange.upperBound)
                    }

                    section("The hold", note: "After the set tone, the start fires at a random moment in this window.") {
                        StepperRow(label: "Shortest", value: $store.settings.holdMinSeconds, step: 0.1,
                                   min: StartSettings.holdRange.lowerBound,
                                   max: store.settings.holdMaxSeconds - StartSettings.minHoldSpread)
                        Rule()
                        StepperRow(label: "Longest", value: $store.settings.holdMaxSeconds, step: 0.1,
                                   min: store.settings.holdMinSeconds + StartSettings.minHoldSpread,
                                   max: StartSettings.holdRange.upperBound)
                    }

                    section("Start sound") {
                        ForEach(StartSound.allCases) { sound in
                            SoundChoice(sound: sound, selected: store.settings.startSound == sound) {
                                store.settings.startSound = sound
                                soundTest.playSingle(sound == .gun ? .gun : .tone)
                            }
                            Rule()
                        }
                        ActionRow(title: soundTest.isPlaying ? "Playing…" : "Hear a full start",
                                  hint: "Plays at your current volume", icon: "speaker.wave.2",
                                  disabled: soundTest.isPlaying) {
                            soundTest.play(startSound: store.settings.startSound)
                        }
                    }

                    section("Recording") {
                        StepperRow(label: "After the start", hint: "Keeps filming through clearance",
                                   value: $store.settings.postGunSeconds, step: 0.5,
                                   min: StartSettings.postGunRange.lowerBound, max: StartSettings.postGunRange.upperBound)
                        Rule()
                        toggleRow("Big screen cues", "Full-screen Set and Go over the camera", isOn: $store.settings.largeCues)
                    }

                    section("Repeat reps") {
                        toggleRow("Run several in a row", "Each rep is saved before the rest begins",
                                  isOn: $store.settings.repeatEnabled)
                        if store.settings.repeatEnabled {
                            Rule()
                            StepperRow(label: "Reps", value: Binding(
                                get: { Double(store.settings.repeatCount) },
                                set: { store.settings.repeatCount = Int($0.rounded()) }
                            ), unit: "", step: 1,
                                       min: Double(StartSettings.repeatCountRange.lowerBound),
                                       max: Double(StartSettings.repeatCountRange.upperBound))
                            Rule()
                            StepperRow(label: "Rest", hint: "Ticks and a tone lead into each rep",
                                       value: $store.settings.restSeconds, step: 15,
                                       min: StartSettings.restRange.lowerBound, max: StartSettings.restRange.upperBound)
                        }
                    }

                    section("Storage", note: "Reps stay on this iPhone only and aren't in iCloud or computer backups. Share a video to keep a copy.") {
                        HStack {
                            Text("Saved reps").font(Theme.Fonts.label).foregroundStyle(Theme.text)
                            Spacer()
                            Text(storageText).font(Theme.Fonts.label).foregroundStyle(Theme.textMuted).monospacedDigit()
                        }
                        .padding(.vertical, 14)
                        Rule()
                        ActionRow(title: "Delete all training data", icon: "trash", destructive: true,
                                  disabled: reps.reps.isEmpty) {
                            confirmDeleteAll = true
                        }
                    }

                    section("Defaults") {
                        ActionRow(title: "Reset settings", hint: "Back to the timing MyBlock ships with",
                                  icon: "arrow.counterclockwise", disabled: store.settings == StartSettings()) {
                            store.settings = StartSettings()
                        }
                    }
                }
                .padding(.top, Theme.Space.md)
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.bottom, Theme.Space.xxl)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .presentationBackground(Theme.background)
        .onAppear(perform: refreshStorage)
        .onChange(of: reps.reps.count) { _, _ in refreshStorage() }
        .confirmationDialog("Delete all training data?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete \(reps.reps.count) reps", role: .destructive) { reps.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every saved video, thumbnail, note and result will be removed from this iPhone. This can't be undone.")
        }
    }

    private func toggleRow(_ title: String, _ hint: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Fonts.label).foregroundStyle(Theme.text)
                Text(hint).textStyle(.small)
            }
        }
        .tint(Theme.red)
        .padding(.vertical, 14)
        .sensoryFeedback(.selection, trigger: isOn.wrappedValue)
    }

    private func refreshStorage() {
        let size = ByteCountFormatter.string(fromByteCount: reps.storageBytes(), countStyle: .file)
        let count = reps.reps.count
        storageText = count == 0 ? "None" : "\(count) · \(size)"
    }

    private static let order = ["Countdown", "The hold", "Start sound", "Recording", "Repeat reps", "Storage", "Defaults"]
    /// Each section gets the next board color, like the circles on the style board.
    private static func accent(for title: String) -> Color {
        Theme.accents[(order.firstIndex(of: title) ?? 0) % Theme.accents.count]
    }

    /// Title, optional note, a navy rule, then the rows.
    private func section<Content: View>(_ title: String, note: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.sm) {
                Circle().fill(Self.accent(for: title)).frame(width: 10, height: 10)
                Text(title)
                    .font(Theme.Fonts.sectionTitle)
                    .foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
            }
            if let note {
                Text(note)
                    .textStyle(.small)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Space.xs)
            }
            Rule(color: Theme.navy).padding(.top, Theme.Space.md)
            content()
        }
    }
}

/// A tappable settings row: title (and hint) left, an icon right.
private struct ActionRow: View {
    let title: String
    var hint: String?
    let icon: String
    var destructive = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.Fonts.label).foregroundStyle(destructive ? Theme.red : Theme.text)
                    if let hint { Text(hint).textStyle(.small) }
                }
                Spacer()
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(destructive ? Theme.red : Theme.navy)
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressFade())
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}

/// One start-sound option as a radio row. Choosing it plays it.
private struct SoundChoice: View {
    let sound: StartSound
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(selected ? Theme.red : Theme.textMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sound.title).font(Theme.Fonts.label).foregroundStyle(Theme.text)
                    Text(sound == .gun ? "A starter's pistol" : "A short electronic beep").textStyle(.small)
                }
                Spacer()
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressFade())
        .accessibilityLabel(sound.title)
        .accessibilityHint("Selects and plays this start sound")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

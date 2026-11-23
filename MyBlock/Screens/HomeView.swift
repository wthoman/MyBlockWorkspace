import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    let onStart: () -> Void
    let onOpen: (UUID) -> Void

    @ObservedObject private var store = RepStore.shared
    @State private var pickerItem: PhotosPickerItem?
    @State private var importing = false
    @State private var importError: String?
    @State private var showSettings = false
    @State private var showGuide = false
    @State private var showHistory = false
    @State private var pendingDelete: Rep?

    private static let recentCount = 3

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                topBar
                    .padding(.horizontal, Theme.Space.gutter - 6)

                // Full-bleed: the track runs edge to edge.
                LaneScene(runners: [.lightBlue, .yellow, .blue], firstLane: 3)
                    .frame(height: 250)
                    .padding(.top, Theme.Space.xs)

                // Navy poster band: the title in white with "track." in sun yellow.
                VStack(alignment: .leading, spacing: 0) {
                    (Text("Own the ") + Text("track.").foregroundColor(Theme.yellow))
                        .font(Theme.Fonts.display)
                        .tracking(-0.8)
                        .foregroundStyle(Theme.white)
                        .minimumScaleFactor(0.6)
                        .lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                    Text("Phone beside your lane, tap Start, and listen for the tones and the gun.")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Theme.Space.sm)

                    MBButton(label: "Start a rep", action: onStart)
                        .accessibilityHint("Opens the camera. Then tap Start again and walk to your blocks.")
                        .padding(.top, Theme.Space.xl)

                    PhotosPicker(selection: $pickerItem, matching: .videos, preferredItemEncoding: .current) {
                        ButtonLabel(label: importing ? "Opening video…" : "Analyze a video from Photos",
                                    variant: .ghost, fill: false, compact: true, ghostColor: Theme.sky)
                    }
                    .buttonStyle(PressStyle())
                    .disabled(importing)
                    .padding(.top, Theme.Space.xs)
                }
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.top, Theme.Space.xl)
                .padding(.bottom, Theme.Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.navy.overlay { PrintGrain(opacity: 0.06, light: true) })

                recent
                    .padding(.horizontal, Theme.Space.gutter)
                    .padding(.top, Theme.Space.xl)
            }
            .padding(.bottom, Theme.Space.xxl)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background.ignoresSafeArea())
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showGuide) { SetupGuideSheet() }
        .sheet(isPresented: $showHistory) {
            HistorySheet { id in
                showHistory = false
                onOpen(id)
            }
        }
        #if DEBUG
        .onAppear {
            switch UserDefaults.standard.string(forKey: "debugSheet") {
            case "settings": showSettings = true
            case "guide": showGuide = true
            case "history": showHistory = true
            default: break
            }
        }
        #endif
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            importVideo(item)
        }
        .alert("Could not open the video", isPresented: Binding(isPresent: $importError)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .confirmationDialog("Delete this rep?", isPresented: Binding(isPresent: $pendingDelete), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let rep = pendingDelete { store.delete(rep.id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The video and its results will be removed from this iPhone.")
        }
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            Text("MyBlock")
                .font(Theme.Fonts.sectionTitle)
                .foregroundStyle(Theme.text)
                .padding(.leading, 6)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            IconButton(systemName: "questionmark.circle", label: "How to set up the phone") { showGuide = true }
            IconButton(systemName: "slider.horizontal.3", label: "Settings") { showSettings = true }
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .firstTextBaseline) {
            Text("Recent reps").font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if store.reps.count > Self.recentCount {
                Button("See all \(store.reps.count)") { showHistory = true }
                    .font(Theme.Fonts.button)
                    .foregroundStyle(Theme.red)
                    .frame(minHeight: Theme.minTouch)
            }
        }
        .padding(.bottom, Theme.Space.sm)

        Rule(color: Theme.navy)
        if store.reps.isEmpty {
            Text("Your reps land here after your first start.")
                .textStyle(.small)
                .padding(.vertical, Theme.Space.lg)
        } else {
            ForEach(store.reps.prefix(Self.recentCount)) { rep in
                Button { onOpen(rep.id) } label: { RepRow(rep: rep) }
                    .buttonStyle(PressFade())
                    .contextMenu {
                        ShareLink(item: store.videoURL(for: rep)) { Label("Share original video", systemImage: "square.and.arrow.up") }
                        Button(role: .destructive) { pendingDelete = rep } label: { Label("Delete", systemImage: "trash") }
                    }
                Rule()
            }
        }
        }
    }

    private func importVideo(_ item: PhotosPickerItem) {
        importing = true
        Task {
            defer {
                importing = false
                pickerItem = nil
            }
            do {
                guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                    throw CocoaError(.fileReadUnknown)
                }
                let rep = try store.add(videoAt: movie.url, sessionID: UUID(), origin: .imported, gunTime: nil,
                                        gunTimeUncertainty: nil, holdSeconds: nil)
                onOpen(rep.id)
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}

/// One saved rep in a ruled list: thumbnail, time, the two scores, the note.
struct RepRow: View {
    let rep: Rep
    @ObservedObject private var store = RepStore.shared

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            thumbnail
                .frame(width: 72, height: 54)
                .clipped()
            VStack(alignment: .leading, spacing: 3) {
                Text(rep.date.repLabel)
                    .font(Theme.Fonts.heading)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                scores
                if !rep.note.isEmpty {
                    Text(rep.note).textStyle(.small).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .accessibilityHidden(true)
        }
        .padding(.vertical, Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rep.date.repLabel). \(rep.summary)\(rep.note.isEmpty ? "" : ". Note: \(rep.note)")")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var scores: some View {
        if !rep.isAnalyzed {
            Text(rep.source == .imported ? "Imported · not checked yet" : "Not checked yet").textStyle(.small)
        } else {
            // Full words when there's room, a compact form when there isn't; never wraps.
            ViewThatFits(in: .horizontal) {
                scoreLine(short: false)
                scoreLine(short: true)
            }
        }
    }

    private func scoreLine(short: Bool) -> some View {
        HStack(spacing: Theme.Space.md) {
            ForEach(FrameKind.allCases) { kind in
                let summary = FrameSummary(metrics: rep.frames[kind]?.metrics ?? [])
                HStack(spacing: 5) {
                    Circle().fill(kind == .set ? Theme.red : Theme.sky).frame(width: 7, height: 7)
                    Text(short ? (kind == .set ? "Set" : "Clear") : kind.shortTitle)
                        .font(Theme.Fonts.small).foregroundStyle(Theme.textMuted)
                    Text(summary.canAssess ? "\(summary.inRange)/\(summary.assessed)" : "–")
                        .font(Theme.Fonts.smallBold).foregroundStyle(Theme.text).monospacedDigit()
                }
                .fixedSize()
            }
            if rep.source == .imported {
                Text("Imported").font(Theme.Fonts.small).foregroundStyle(Theme.textMuted).fixedSize()
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder private var thumbnail: some View {
        let _ = store.thumbnailVersion
        if let image = UIImage(contentsOfFile: store.thumbnailURL(for: rep).path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                TrackColors.surface
                Image(systemName: "video.fill").foregroundStyle(Theme.white)
            }
        }
    }
}

/// All saved reps, grouped by practice session, newest first.
struct HistorySheet: View {
    let onOpen: (UUID) -> Void
    @ObservedObject private var store = RepStore.shared
    @Environment(\.dismiss) private var dismiss

    private var sessions: [(id: UUID, date: Date, reps: [Rep])] {
        var order: [UUID] = []
        var groups: [UUID: [Rep]] = [:]
        for rep in store.reps {
            if groups[rep.sessionID] == nil { order.append(rep.sessionID) }
            groups[rep.sessionID, default: []].append(rep)
        }
        return order.map { id in (id, groups[id]!.first!.date, groups[id]!) }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "All reps") { dismiss() }
            List {
                ForEach(sessions, id: \.id) { session in
                    Section {
                        ForEach(session.reps) { rep in
                            Button { onOpen(rep.id) } label: { RepRow(rep: rep) }
                                .buttonStyle(PressFade())
                                .listRowBackground(Color.clear)
                                .listRowSeparatorTint(Theme.hairline)
                                .listRowInsets(EdgeInsets(top: 0, leading: Theme.Space.gutter, bottom: 0, trailing: Theme.Space.gutter))
                                .swipeActions {
                                    Button(role: .destructive) { store.delete(rep.id) } label: { Label("Delete", systemImage: "trash") }
                                    ShareLink(item: store.videoURL(for: rep)) { Label("Share", systemImage: "square.and.arrow.up") }
                                }
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(session.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                                    .font(Theme.Fonts.heading).foregroundStyle(Theme.text)
                                Spacer()
                                Text("\(session.reps.count) rep\(session.reps.count == 1 ? "" : "s")")
                                    .font(Theme.Fonts.meta).foregroundStyle(Theme.textMuted)
                            }
                            Rule(color: Theme.navy)
                        }
                        .padding(.top, Theme.Space.lg)
                        .background(Theme.background)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if store.reps.isEmpty { Text("No saved reps yet.").textStyle(.body) }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .presentationBackground(Theme.background)
    }
}

/// Title and Done for sheets.
struct SheetHeader: View {
    let title: String
    let onDone: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(Theme.Fonts.screenTitle)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button("Done", action: onDone)
                .font(Theme.Fonts.button)
                .foregroundStyle(Theme.red)
                .frame(minWidth: Theme.minTouch, minHeight: Theme.minTouch)
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, Theme.Space.xl)
        .padding(.bottom, Theme.Space.sm)
    }
}

extension Date {
    /// "Today · 4:32 PM", "Yesterday · 9:05 AM", or "Mar 3 · 4:32 PM".
    var repLabel: String {
        let cal = Calendar.current
        let day = cal.isDateInToday(self) ? "Today"
            : cal.isDateInYesterday(self) ? "Yesterday"
            : formatted(.dateTime.month(.abbreviated).day())
        return "\(day) · \(formatted(date: .omitted, time: .shortened))"
    }
}

/// A video picked from Photos, copied into the app's temporary folder.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("import-\(UUID().uuidString)")
                .appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

// Saved reps live in Application Support/Reps/<id>/ as video + thumbnail + rep.json.
// The folder is excluded from iCloud and computer backups, so recordings exist only on
// this iPhone until the athlete shares or saves one.

import AVFoundation
import UIKit

@MainActor
final class RepStore: ObservableObject {
    enum StoreError: LocalizedError {
        case lowStorage
        case saveFailed(String)
        var errorDescription: String? {
            switch self {
            case .lowStorage: "Your iPhone is almost out of storage. Free up some space, then try again."
            case let .saveFailed(reason): "The recording could not be saved. \(reason)"
            }
        }
    }

    static let shared = RepStore()

    /// Newest first.
    @Published private(set) var reps: [Rep] = []

    let root: URL
    private let fm = FileManager.default

    /// Free space needed before a recording is started (a rep is roughly 10–40 MB).
    static let minimumFreeBytes: Int64 = 300 * 1024 * 1024

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true))
                ?? FileManager.default.temporaryDirectory
            self.root = support.appendingPathComponent("Reps", isDirectory: true)
        }
        prepareRoot()
        reload()
    }

    private func prepareRoot() {
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: Paths

    func folder(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func videoURL(for rep: Rep) -> URL { folder(for: rep.id).appendingPathComponent(rep.videoFileName) }
    func thumbnailURL(for rep: Rep) -> URL { folder(for: rep.id).appendingPathComponent("thumb.jpg") }
    private func metadataURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("rep.json") }

    func rep(_ id: UUID) -> Rep? { reps.first { $0.id == id } }

    // MARK: Loading

    func reload() {
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Rep] = []
        for folder in folders where folder.hasDirectoryPath {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            if let data = try? Data(contentsOf: metadataURL(for: id)),
               let rep = try? JSONDecoder.repDecoder.decode(Rep.self, from: data) {
                loaded.append(rep)
            } else if let recovered = recover(folder: folder, id: id) {
                // A video without readable metadata (e.g. the app quit mid-save): keep it.
                loaded.append(recovered)
            }
        }
        reps = loaded.sorted { $0.date > $1.date }
        for rep in reps where !fm.fileExists(atPath: thumbnailURL(for: rep).path) {
            makeThumbnail(for: rep)
        }
    }

    private func recover(folder: URL, id: UUID) -> Rep? {
        let files = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        guard let video = files.first(where: { ["mov", "mp4", "m4v"].contains(($0 as NSString).pathExtension.lowercased()) })
        else { return nil }
        let date = (try? fm.attributesOfItem(atPath: folder.appendingPathComponent(video).path)[.creationDate] as? Date) ?? Date()
        let rep = Rep(id: id, date: date, sessionID: UUID(), source: .recorded, videoFileName: video,
                      gunTime: nil, gunTimeUncertainty: nil, holdSeconds: nil)
        try? write(rep)
        return rep
    }

    // MARK: Saving

    static func hasSpaceForRecording() -> Bool {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage else { return true }
        return free >= minimumFreeBytes
    }

    /// Moves a finished recording (or imported clip) into the store. The source file is only
    /// removed after it has been copied successfully, so a failed save never loses the video.
    @discardableResult
    func add(videoAt source: URL, sessionID: UUID, origin: Rep.Source, gunTime: Double?,
             gunTimeUncertainty: Double?, holdSeconds: Double?, date: Date = Date()) throws -> Rep {
        let id = UUID()
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased()
        let rep = Rep(id: id, date: date, sessionID: sessionID, source: origin, videoFileName: "video.\(ext)",
                      gunTime: gunTime, gunTimeUncertainty: gunTimeUncertainty, holdSeconds: holdSeconds)
        let folder = folder(for: id)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = videoURL(for: rep)
            do {
                try fm.moveItem(at: source, to: dest)
            } catch {
                try fm.copyItem(at: source, to: dest)
                try? fm.removeItem(at: source)
            }
            try write(rep)
        } catch {
            // Leave the source where it was; only clean up the half-made folder if the video never got there.
            if !fm.fileExists(atPath: videoURL(for: rep).path) { try? fm.removeItem(at: folder) }
            throw StoreError.saveFailed(Self.describe(error))
        }
        reps.insert(rep, at: 0)
        reps.sort { $0.date > $1.date }
        makeThumbnail(for: rep)
        return rep
    }

    func update(_ rep: Rep) throws {
        try write(rep)
        if let i = reps.firstIndex(where: { $0.id == rep.id }) { reps[i] = rep }
    }

    private func write(_ rep: Rep) throws {
        let data = try JSONEncoder.repEncoder.encode(rep)
        try data.write(to: metadataURL(for: rep.id), options: .atomic)
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError {
            return "Your iPhone is out of storage."
        }
        return ns.localizedDescription
    }

    // MARK: Deleting

    func delete(_ id: UUID) {
        try? fm.removeItem(at: folder(for: id))
        reps.removeAll { $0.id == id }
    }

    /// Removes every rep: videos, thumbnails and analysis.
    func deleteAll() {
        for rep in reps { try? fm.removeItem(at: folder(for: rep.id)) }
        // Anything else left in the folder (unreadable leftovers) goes too.
        for url in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: url)
        }
        reps = []
    }

    /// Total size of everything saved, bytes.
    func storageBytes() -> Int64 {
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    // MARK: Thumbnails

    /// Bumped when a thumbnail is written so rows showing it refresh.
    @Published private(set) var thumbnailVersion = 0

    private func makeThumbnail(for rep: Rep) {
        let video = videoURL(for: rep), dest = thumbnailURL(for: rep)
        let time = max(0, (rep.gunTime ?? 0.5) - 0.1)
        Task.detached(priority: .utility) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 320)
            guard let (image, _) = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)),
                  let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.7) else { return }
            try? data.write(to: dest, options: .atomic)
            await MainActor.run { self.thumbnailVersion += 1 }
        }
    }
}

extension JSONEncoder {
    static var repEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var repDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// Remembers the athlete's settings and whether the intro has been seen.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    private static let key = "startSettings.v2"

    private let defaults: UserDefaults

    @Published var settings: StartSettings {
        didSet {
            let clean = settings.sanitized()
            if clean != settings { settings = clean; return }
            if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.key) }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(StartSettings.self, from: data) {
            settings = saved
        } else {
            settings = StartSettings()
        }
    }
}

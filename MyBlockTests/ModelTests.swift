import XCTest
@testable import MyBlock

final class SettingsTests: XCTestCase {
    func testSanitizeKeepsHoldWindowValidAndUnpredictable() {
        var s = StartSettings()
        s.holdMinSeconds = 3.9
        s.holdMaxSeconds = 2.0
        let clean = s.sanitized()
        XCTAssertGreaterThanOrEqual(clean.holdMaxSeconds - clean.holdMinSeconds, StartSettings.minHoldSpread - 1e-9)
        XCTAssertLessThanOrEqual(clean.holdMaxSeconds, StartSettings.holdRange.upperBound)
        XCTAssertGreaterThanOrEqual(clean.holdMinSeconds, StartSettings.holdRange.lowerBound)
    }

    func testSanitizeClampsEverything() {
        var s = StartSettings()
        s.prepSeconds = 0
        s.postGunSeconds = 99
        s.repeatCount = 50
        let clean = s.sanitized()
        XCTAssertEqual(clean.prepSeconds, StartSettings.prepRange.lowerBound)
        XCTAssertEqual(clean.postGunSeconds, StartSettings.postGunRange.upperBound)
        XCTAssertEqual(clean.repeatCount, StartSettings.repeatCountRange.upperBound)
    }

    func testDecodesPartialOrOldSettingsWithDefaults() throws {
        let json = #"{"prepSeconds": 20, "startSound": "somethingNew"}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(StartSettings.self, from: json)
        XCTAssertEqual(s.prepSeconds, 20)
        XCTAssertEqual(s.startSound, .gun)
        XCTAssertEqual(s.marksSeconds, StartSettings().marksSeconds)
        XCTAssertFalse(s.repeatEnabled, "repeated reps stay off by default")
    }

    func testDefaultsWorkWithoutOpeningSettings() {
        let s = StartSettings()
        XCTAssertEqual(s, s.sanitized())
        XCTAssertEqual(s.repsPerRun, 1)
        XCTAssertEqual(s.startSound, .gun)
    }
}

@MainActor
final class RepStoreTests: XCTestCase {
    var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RepStoreTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeVideo() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v-\(UUID().uuidString).mov")
        try Data("not really a movie".utf8).write(to: url)
        return url
    }

    func testAddPersistsAndReloads() throws {
        let store = RepStore(root: root)
        let source = try makeVideo()
        let session = UUID()
        var rep = try store.add(videoAt: source, sessionID: session, origin: .recorded, gunTime: 2.4,
                                gunTimeUncertainty: 0.05, holdSeconds: 2.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "moved, not copied")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.videoURL(for: rep).path))

        let pose: Pose = [.leftHip: Landmark(x: 0.5, y: 0.5, confidence: 0.9)]
        rep.frames[.set] = RepFrame(kind: .set, time: 2.3, width: 1280, height: 720, pose: pose, adjusted: true)
        rep.note = "Windy"
        try store.update(rep)

        let reloaded = RepStore(root: root)
        let back = try XCTUnwrap(reloaded.rep(rep.id))
        XCTAssertEqual(back.sessionID, session)
        XCTAssertEqual(back.gunTime, 2.4)
        XCTAssertEqual(back.note, "Windy")
        XCTAssertEqual(back.frames[.set]?.adjusted, true, "a manual correction is kept")
        XCTAssertEqual(back.frames[.set]?.time, 2.3)
        XCTAssertEqual(back.frames[.set]?.pose?[.leftHip], pose[.leftHip])
        XCTAssertNil(back.frames[.clearance])
    }

    func testFolderIsExcludedFromBackup() throws {
        let store = RepStore(root: root)
        let values = try store.root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testDeleteRemovesEverythingForThatRep() throws {
        let store = RepStore(root: root)
        let a = try store.add(videoAt: makeVideo(), sessionID: UUID(), origin: .recorded, gunTime: 1,
                              gunTimeUncertainty: 0.05, holdSeconds: 2)
        let b = try store.add(videoAt: makeVideo(), sessionID: UUID(), origin: .imported, gunTime: nil,
                              gunTimeUncertainty: nil, holdSeconds: nil)
        store.delete(a.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(for: a.id).path))
        XCTAssertNotNil(store.rep(b.id))
        store.deleteAll()
        XCTAssertTrue(store.reps.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testFailedSaveKeepsTheSourceRecording() throws {
        let store = RepStore(root: root)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).mov")
        XCTAssertThrowsError(try store.add(videoAt: missing, sessionID: UUID(), origin: .recorded, gunTime: 1,
                                           gunTimeUncertainty: 0.05, holdSeconds: 2))
        XCTAssertTrue(store.reps.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [], "no half-made folders")
    }

    func testVideoWithoutMetadataIsRecoveredNotDropped() throws {
        let id = UUID()
        let folder = root.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("movie".utf8).write(to: folder.appendingPathComponent("video.mov"))
        let store = RepStore(root: root)
        XCTAssertEqual(store.rep(id)?.videoFileName, "video.mov")
    }
}

final class CoachingTests: XCTestCase {
    private func metric(_ id: MetricID, _ grade: Grade, cue: String = "") -> MetricResult {
        MetricResult(id: id, label: id.rawValue, value: grade == .unknown ? nil : 90, grade: grade,
                     target: "", cue: cue.isEmpty ? id.rawValue : cue, anchor: .leftHip)
    }

    func testRedSetIssueComesFirst() {
        let cue = Coaching.mainCue(
            set: [metric(.frontKnee, .yellow), metric(.rearHip, .red, cue: "fix rear hip")],
            clearance: [metric(.pushKnee, .red)]
        )
        XCTAssertEqual(cue.text, "fix rear hip")
        XCTAssertEqual(cue.kind, .set)
    }

    func testRedClearanceBeatsYellowSet() {
        let cue = Coaching.mainCue(set: [metric(.frontKnee, .yellow)], clearance: [metric(.driveAngle, .red)])
        XCTAssertEqual(cue.metric, .driveAngle)
    }

    func testUnmeasuredDoesNotBecomeACue() {
        let cue = Coaching.mainCue(set: [metric(.frontKnee, .unknown), metric(.rearKnee, .green)],
                                   clearance: [metric(.pushKnee, .unknown)])
        XCTAssertNil(cue.kind)
        XCTAssertTrue(cue.text.contains("inside the guide ranges"))
    }

    func testNothingMeasuredSaysSo() {
        let cue = Coaching.mainCue(set: [metric(.frontKnee, .unknown)], clearance: nil)
        XCTAssertTrue(cue.text.contains("weren't clear enough"))
    }

    func testSummaryDoesNotPenaliseMissingJoints() {
        let s = FrameSummary(metrics: [metric(.frontKnee, .green), metric(.rearKnee, .unknown), metric(.frontHip, .red)])
        XCTAssertEqual(s.headline, "1 of 2 in guide range")
        XCTAssertNotNil(s.confidenceNote)
        XCTAssertEqual(FrameSummary(metrics: [metric(.frontKnee, .unknown)]).headline, "Unable to assess")
    }

    func testRelativeTimeShowsUncertainty() {
        XCTAssertEqual(Coaching.relativeTimeText(time: 2.0, gunTime: 2.1, uncertainty: 0.05),
                       "0.10 s before the start · ±0.05 s")
        XCTAssertNil(Coaching.relativeTimeText(time: 2.0, gunTime: nil, uncertainty: nil))
    }

    func testMissingJointsAreUnableToAssessNotRed() {
        // A pose with only the hips: knee and hip angles can't be measured.
        let pose: Pose = [.leftHip: Landmark(x: 0.4, y: 0.5, confidence: 0.9),
                          .rightHip: Landmark(x: 0.42, y: 0.5, confidence: 0.9)]
        let metrics = Analysis.analyzeFrame(kind: .set, pose: pose, width: 1920, height: 1080)
        XCTAssertTrue(metrics.allSatisfy { $0.grade == .unknown })
        XCTAssertTrue(metrics.allSatisfy { $0.cue.hasPrefix("Unable to assess") })
    }
}

final class PoseDetectorTests: XCTestCase {
    /// A blank frame has nobody in it: detection must return nil, not throw.
    func testDetectorRunsOnAnEmptyFrame() throws {
        #if targetEnvironment(simulator)
        let isSimulator = true
        #else
        let isSimulator = false
        #endif
        try XCTSkipIf(isSimulator, "Vision body-pose detection doesn't run in the Simulator; run this test on an iPhone.")
        let size = CGSize(width: 640, height: 360)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.darkGray.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        let pose = try PoseDetector.detect(in: XCTUnwrap(image.cgImage))
        XCTAssertNil(pose)
    }

    func testSimulatorVisionFailureGetsAPlainMessage() async throws {
        #if targetEnvironment(simulator)
        let image = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { _ in }.cgImage)
        do {
            _ = try await FrameAnalyzer.detectPose(in: image)
        } catch {
            XCTAssertTrue(error is AnalysisError, "raw Vision error leaked: \(error)")
        }
        #endif
    }
}

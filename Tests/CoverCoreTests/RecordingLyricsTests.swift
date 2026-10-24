import Foundation
import XCTest
@testable import CoverCore

final class RecordingLyricsTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingLyrics-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func project(_ repository: ProjectRepository) async throws -> StudioProject {
        let asset = MediaAsset(path: "media/backing.wav", role: .backing, bytes: 4, sha256: String(repeating: "a", count: 64), duration: .init(seconds: 180))
        let arrangement = Arrangement(sourceAssetID: asset.id, isBacking: true)
        var project = StudioProject(song: .init(title: "起点与歌词"), arrangement: arrangement, assets: [asset], sourceDeviceID: "test")
        let directory = try await repository.makeDirectory(project.id)
        try Data([1, 2, 3, 4]).write(to: directory.appendingPathComponent(asset.path))
        project.assets[0].sha256 = try FileIntegrity.sha256(directory.appendingPathComponent(asset.path))
        try await repository.save(project)
        return project
    }

    func testThreeFullTakeOriginsIgnorePreviousPracticeAndRecordingPositions() async throws {
        let repository = try ProjectRepository(root: root())
        var project = try await project(repository)
        let bytes = try Data(contentsOf: repository.directory(project.id).appendingPathComponent("media/backing.wav"))
        var previousTakes: [Take] = []
        for oldPosition in [83.0, 49.2, 180.0] {
            let origin = RecordingOrigin.session(practice: false, playbackPosition: oldPosition)
            let start = try origin.position(duration: 180)
            XCTAssertEqual(start, 0)
            let take = Take(name: "Take \(previousTakes.count + 1)", kind: .audio, arrangementID: project.arrangementID, semitones: 0)
            project = try await repository.beginRecordingTake(project, take: take)
            let segment = RecordingSegment(vocalAssetID: project.assets[0].id, videoAssetID: nil,
                songStart: .init(seconds: start), hostStart: .init(seconds: 1), duration: .init(seconds: 10),
                audioFirstPTS: nil, videoFirstPTS: nil, playbackHostTime: 1, inputLatency: 0, outputLatency: 0, route: "metadata test only")
            project.takes[project.takes.count - 1].segments = [segment]
            project.touch(); try await repository.save(project)
            try await repository.completeRecordingTake(project, takeID: take.id)
            XCTAssertEqual(Array(project.takes.dropLast()), previousTakes)
            previousTakes = project.takes
        }
        let reloaded = try await repository.loadAll()
        XCTAssertEqual(reloaded.first?.takes, previousTakes)
        XCTAssertEqual(try Data(contentsOf: repository.directory(project.id).appendingPathComponent("media/backing.wav")), bytes)
        // Tests persisted origins and original preservation, not physical audio/video capture.
    }

    func testPracticeSectionAndRecoveryHaveIndependentOrigins() throws {
        XCTAssertEqual(try RecordingOrigin.session(practice: true, playbackPosition: 38).position(duration: 180), 38)
        XCTAssertEqual(try RecordingOrigin.session(practice: true, playbackPosition: 180).position(duration: 180), 0)
        XCTAssertEqual(try RecordingOrigin.session(practice: false, playbackPosition: 95, sectionStart: 24).position(duration: 180), 24)
        XCTAssertEqual(try RecordingOrigin.session(practice: false, playbackPosition: 95, sectionStart: 24, recoveringEnd: 40).position(duration: 180), 37)
        XCTAssertEqual(try RecordingOrigin.recovery(savedEnd: 2).position(duration: 180), 0)
        for invalid in [Double.nan, -Double.infinity, -1, 180, 200] {
            XCTAssertThrowsError(try RecordingOrigin.section(start: invalid).position(duration: 180))
        }
        XCTAssertThrowsError(try RecordingOrigin.fullTake.position(duration: 0))
    }

    func testLyricsFilesReadTXTAndLRCWithUnicodeBOMAndConcreteFailures() throws {
        let directory = try root(), txt = directory.appendingPathComponent("中文.TXT"), lrc = directory.appendingPathComponent("同步.lrc")
        let words = "第一句 👩🏽‍🎤\n第二句 café"
        try (Data([0xEF, 0xBB, 0xBF]) + Data(words.utf8)).write(to: txt)
        XCTAssertEqual(try LyricsDocument.read(txt), words)
        XCTAssertFalse(LRCParser.parse(try LyricsDocument.read(txt)).lyrics.isTimed)
        let timed = "[offset:-250]\n[00:01.00]第一句\n[00:05.00]第二句"
        try (Data([0xFF, 0xFE]) + timed.data(using: .utf16LittleEndian)!).write(to: lrc)
        let parsed = LRCParser.parse(try LyricsDocument.read(lrc)).lyrics
        XCTAssertTrue(parsed.isTimed); XCTAssertEqual(parsed.activeIndex(at: 0.74), nil)
        XCTAssertEqual(parsed.activeIndex(at: 0.75), 0); XCTAssertEqual(parsed.activeIndex(at: 4.75), 1)
        XCTAssertNil(parsed.activeIndex(at: 0))
        try Data([0, 1, 2]).write(to: txt)
        XCTAssertThrowsError(try LyricsDocument.read(txt))
        try Data([0xC3, 0x28]).write(to: txt)
        XCTAssertThrowsError(try LyricsDocument.read(txt))
        XCTAssertThrowsError(try LyricsDocument.decode(Data()))
        XCTAssertThrowsError(try LyricsDocument.decode(Data(repeating: 65, count: LyricsDocument.maximumBytes + 1)))
        XCTAssertThrowsError(try LyricsDocument.read(directory.appendingPathComponent("song.pdf")))
        XCTAssertThrowsError(try LyricsDocument.read(directory.appendingPathComponent("missing.txt")))
    }

    func testEditedLyricsPersistOnArrangementAndPreserveOtherVersionsAndTakes() async throws {
        let repository = try ProjectRepository(root: root())
        var project = try await project(repository)
        var other = project.arrangements[0]; other.id = UUID(); other.lyrics = LRCParser.parse("旧版本歌词").lyrics
        project.arrangements.append(other)
        let oldTake = Take(name: "保留 Take", kind: .audio, arrangementID: other.id, semitones: 2)
        project.takes = [oldTake]; project.touch(); try await repository.save(project)
        let savedLyrics = LRCParser.parse("[00:02.00]粘贴后直接保存\n[00:06.00]切换页面仍在").lyrics
        project = try LyricsDocument.applying(savedLyrics, to: project, arrangementID: project.arrangementID)
        try await repository.save(project)
        let reopened = try ProjectRepository(root: repository.root)
        let projects = try await reopened.loadAll(), loaded = try XCTUnwrap(projects.first)
        XCTAssertEqual(loaded.arrangement?.lyrics, savedLyrics)
        XCTAssertEqual(loaded.arrangement(for: oldTake)?.lyrics, other.lyrics)
        XCTAssertEqual(loaded.takes, [oldTake])
        let editedTXT = LRCParser.parse("重新修改\n普通文本").lyrics
        let edited = try LyricsDocument.applying(editedTXT, to: loaded, arrangementID: loaded.arrangementID)
        try await reopened.save(edited)
        let latest = try await reopened.loadAll()
        XCTAssertEqual(latest.first?.arrangement?.lyrics, editedTXT)
        XCTAssertFalse(editedTXT.isTimed)
        XCTAssertThrowsError(try LyricsDocument.applying(savedLyrics, to: loaded, arrangementID: UUID()))
        var invalid = savedLyrics; invalid.offset = .nan
        XCTAssertThrowsError(try LyricsDocument.applying(invalid, to: loaded, arrangementID: loaded.arrangementID))
    }

    func testReopeningLyricDraftPreservesNegativeOffsetAndUntimedLines() {
        let original = LRCParser.parse("[offset:-1000]\n[00:00.20]很早的一句\n无时间点").lyrics
        let roundTrip = LRCParser.parse(LyricsDocument.editableText(original)).lyrics
        XCTAssertEqual(roundTrip.lines.map(\.text), original.lines.map(\.text))
        XCTAssertEqual(roundTrip.lines.map(\.time), original.lines.map(\.time))
        XCTAssertEqual(roundTrip.offset, original.offset)
    }
}

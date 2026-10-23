import Foundation
import XCTest
@testable import CoverCore

final class CoverCoreTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CoverCoreTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func asset(_ name: String, role: AssetRole = .vocal, root: URL) throws -> MediaAsset {
        let path = (role == .export ? "exports/" : "media/") + name
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(("test fixture: " + name).utf8)
        try data.write(to: url)
        return try MediaAsset(path: path, role: role, bytes: Int64(data.count), sha256: FileIntegrity.sha256(url), duration: .init(seconds: 12))
    }

    private func segment(_ vocal: MediaAsset, start: Double = 0, duration: Double = 12) -> RecordingSegment {
        .init(vocalAssetID: vocal.id, videoAssetID: nil, songStart: .init(seconds: start), hostStart: .init(seconds: 100 + start),
              duration: .init(seconds: duration), audioFirstPTS: .init(seconds: 100 + start), videoFirstPTS: nil,
              playbackHostTime: 1, inputLatency: 0.01, outputLatency: 0.02, route: "test route")
    }

    private func makeProject(root: URL) throws -> StudioProject {
        let backing = try asset("backing.wav", role: .backing, root: root)
        let vocal = try asset("vocal.caf", root: root)
        let arrangement = Arrangement(sourceAssetID: backing.id, isBacking: true)
        var project = StudioProject(song: .init(title: "测试歌曲", artist: "歌手"), arrangement: arrangement,
                                    assets: [backing, vocal], sourceDeviceID: "test-device")
        var take = Take(name: "Take 1", kind: .audio, arrangementID: arrangement.id, semitones: 0)
        take.segments = [segment(vocal)]
        project.takes = [take]; project.edit.selectedTakeID = take.id
        return project
    }

    /// Builds intentionally hostile envelopes without using the validated archive writer.
    private func writeEnvelope(_ manifest: ArchiveManifest, media: Data = Data(), to url: URL) throws {
        let json = try FileIntegrity.encoder().encode(manifest)
        var data = ProjectArchive.magic
        var length = UInt64(json.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(FileIntegrity.digest(json)); data.append(json); data.append(media)
        try data.write(to: url)
    }

    func testLRCUnicodeMultipleTagsOffsetAndMetadata() {
        let result = LRCParser.parse("[ti:标题]\n[offset:-250]\n[00:12.50][00:30.00]你好 👩🏽‍🎤 café\n[00:02.00]早上好")
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(result.lyrics.lines.map(\.text), ["早上好", "你好 👩🏽‍🎤 café", "你好 👩🏽‍🎤 café"])
        XCTAssertEqual(result.lyrics.lines.compactMap(\.time), [2, 12.5, 30])
        XCTAssertEqual(result.lyrics.offset, -0.25)
        XCTAssertEqual(result.lyrics.activeIndex(at: 12.3), 1)
        XCTAssertTrue(result.lyrics.isTimed)
    }

    func testMalformedLRCDoesNotInventSynchronizedLyrics() {
        let result = LRCParser.parse("[00:61.00]保留文字\n没有时间\n[wrong]另一句")
        XCTAssertFalse(result.lyrics.isTimed)
        XCTAssertEqual(result.lyrics.lines.count, 3)
        XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertEqual(result.lyrics.lines.first?.text, "保留文字")
    }

    func testLRCRoundingCrossesMinuteBoundary() {
        var lyrics = Lyrics(); lyrics.lines = [.init(text: "边界", time: 59.999)]
        XCTAssertEqual(lyrics.lrc(), "[01:00.00]边界")
        XCTAssertEqual(LRCParser.parse(lyrics.lrc()).lyrics.lines.first?.time, 60)
    }

    func testTimelineResumedOverlapAndTrimPreserveSourceOffset() throws {
        let root = try temporaryDirectory(), vocal = try asset("vocal.caf", root: root)
        var take = Take(name: "resumed", kind: .audio, arrangementID: UUID(), semitones: 0)
        take.segments = [segment(vocal, duration: 10), segment(vocal, start: 7, duration: 5)]
        var edit = EditGraph(); edit.trimStart = 3; edit.trimEnd = 11
        let regions = Timeline.regions(take: take, edit: edit)
        XCTAssertEqual(regions.map(\.duration), [7, 5])
        let range = try Timeline.range(take: take, edit: edit)
        let cropped = try XCTUnwrap(Timeline.crop(regions[0], range: range))
        XCTAssertEqual(cropped.sourceStart, 3); XCTAssertEqual(cropped.start, 0); XCTAssertEqual(cropped.duration, 4)
        let shifted = try XCTUnwrap(Timeline.crop(regions[1], range: range, offset: 1))
        XCTAssertEqual(shifted.start, 5); XCTAssertEqual(shifted.duration, 3)
        XCTAssertNil(Timeline.crop(regions[0], range: 20...25))
        XCTAssertNil(Timeline.crop(regions[0], range: 0...12, offset: .infinity))
        edit.trimEnd = 2
        XCTAssertThrowsError(try Timeline.range(take: take, edit: edit))
        edit.trimStart = -1; edit.trimEnd = 5
        XCTAssertThrowsError(try Timeline.range(take: take, edit: edit))
    }

    func testExportPresetsGuardRealLyricsAndVisuals() throws {
        var preset = ExportPreset(), lyrics = Lyrics()
        XCTAssertEqual(preset.variants, [.subtitledVideo, .cleanVideo])
        XCTAssertThrowsError(try preset.validate(lyrics: lyrics, hasVideo: true))
        lyrics.lines = [.init(text: "歌词", time: 0)]
        XCTAssertNoThrow(try preset.validate(lyrics: lyrics, hasVideo: true))
        XCTAssertThrowsError(try preset.validate(lyrics: lyrics, hasVideo: false))
        preset.variants = [.mixAudio]
        XCTAssertNoThrow(try preset.validate(lyrics: Lyrics(), hasVideo: false))
        preset.variants = []
        XCTAssertThrowsError(try preset.validate(lyrics: lyrics, hasVideo: true))
    }

    func testSafePathsRejectTraversalAndUnsafeComponents() {
        for path in ["", "/media/a", "../a", "media/../a", "media//a", "media/./a", "C:/a", "media\\a", "media/a\u{0}", "media/a.", "media/a ", "media/a\nb"] {
            XCTAssertFalse(ProjectRules.safePath(path), path)
        }
        XCTAssertTrue(ProjectRules.safePath("media/音频/Take 1.caf"))
    }

    func testMetadataCollisionCaseCollisionAndDirectoryCollisionRejected() throws {
        let root = try temporaryDirectory()
        let original = try makeProject(root: root)
        for path in ["project.json", "metadata/a", "media/vocal.caf/child", "MEDIA/BACKING.WAV"] {
            var project = original
            var extra = try asset(UUID().uuidString + ".caf", root: root)
            extra.path = path; project.assets.append(extra)
            XCTAssertThrowsError(try ProjectRules.validate(project), path)
        }
    }

    func testSymbolicLinkCannotEscapeOrAliasMetadata() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory().appendingPathComponent("private.wav")
        try Data("original".utf8).write(to: outside)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("media"), withIntermediateDirectories: true)
        let link = root.appendingPathComponent("media/link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try ProjectRules.mediaURL("media/link.wav", root: root))
        XCTAssertThrowsError(try ProjectRules.mediaURL("project.json", root: root))
        XCTAssertThrowsError(try ProjectRules.mediaURL("exports/queue.json", root: root))
    }

    func testSlimAndCustomKeepReferencedOldTakesAndArrangementDependencies() throws {
        let root = try temporaryDirectory()
        var project = try makeProject(root: root)
        let oldVocal = try asset("old.caf", root: root), unusedVocal = try asset("unused.caf", root: root)
        let oldBacking = try asset("old-backing.wav", role: .backing, root: root)
        let oldArrangement = Arrangement(sourceAssetID: oldBacking.id, isBacking: true)
        var old = Take(name: "referenced", kind: .audio, arrangementID: oldArrangement.id, semitones: -2)
        old.segments = [segment(oldVocal)]
        var unused = Take(name: "unused", kind: .audio, arrangementID: project.arrangementID, semitones: 0)
        unused.segments = [segment(unusedVocal)]
        project.arrangements.append(oldArrangement); project.takes += [old, unused]
        project.assets += [oldVocal, unusedVocal, oldBacking]; project.edit.referencedTakeIDs = [old.id]
        let slim = try ProjectRules.backupProject(project, mode: .slim)
        XCTAssertEqual(Set(slim.takes.map(\.id)), [project.takes[0].id, old.id])
        XCTAssertTrue(slim.assets.contains { $0.id == oldBacking.id })
        XCTAssertFalse(slim.assets.contains { $0.id == unusedVocal.id })
        let custom = try ProjectRules.backupProject(project, mode: .custom, selected: [unused.id])
        XCTAssertEqual(custom.takes.count, 3)
        XCTAssertThrowsError(try ProjectRules.backupProject(project, mode: .custom, selected: [UUID()]))
    }

    func testCompleteBackupIncludesPracticeButExportsAreExplicit() throws {
        let root = try temporaryDirectory()
        var project = try makeProject(root: root)
        var practice = project.takes[0]; practice.id = UUID(); practice.isPractice = true
        project.takes.append(practice)
        let export = try asset("complete.m4a", role: .export, root: root); project.assets.append(export)
        let full = try ProjectRules.backupProject(project, mode: .full)
        XCTAssertEqual(full.takes.count, 2); XCTAssertFalse(full.assets.contains { $0.id == export.id })
        XCTAssertTrue(try ProjectRules.backupProject(project, mode: .full, includeExports: true).assets.contains { $0.id == export.id })
        XCTAssertTrue(try ProjectRules.backupProject(project, mode: .custom, includeExports: true).assets.contains { $0.id == export.id })
        XCTAssertFalse(try ProjectRules.backupProject(project, mode: .slim, includeExports: true).assets.contains { $0.id == export.id })
    }

    func testArchiveRoundTripVerifiesEveryOriginalByte() throws {
        let root = try temporaryDirectory(), project = try makeProject(root: root)
        let archive = root.appendingPathComponent("roundtrip.coverproject"), staging = root.appendingPathComponent("restored")
        let created = try ProjectArchive.create(project: project, root: root, destination: archive, mode: .full)
        let restored = try ProjectArchive.inspect(archive, extractTo: staging)
        XCTAssertEqual(created.archiveID, restored.archiveID)
        XCTAssertEqual(restored.project, project)
        for asset in project.assets {
            XCTAssertEqual(try Data(contentsOf: staging.appendingPathComponent(asset.path)), try Data(contentsOf: root.appendingPathComponent(asset.path)))
        }
        XCTAssertThrowsError(try ProjectArchive.create(project: project, root: root, destination: archive, mode: .full))
    }

    func testArchiveRejectsManifestTamperMediaTamperTruncationAndTrailingBytes() throws {
        let root = try temporaryDirectory(), project = try makeProject(root: root)
        let archive = root.appendingPathComponent("original.coverproject")
        try ProjectArchive.create(project: project, root: root, destination: archive, mode: .full)
        let original = try Data(contentsOf: archive)
        var manifestTamper = original; manifestTamper[48] ^= 1
        var mediaTamper = original; mediaTamper[mediaTamper.count - 1] ^= 1
        var trailing = original; trailing.append(0)
        for (index, data) in [manifestTamper, mediaTamper, Data(original.dropLast()), trailing].enumerated() {
            let bad = root.appendingPathComponent("bad-\(index).coverproject"); try data.write(to: bad)
            XCTAssertThrowsError(try ProjectArchive.inspect(bad))
        }
    }

    func testArchiveRejectsIncompatibleVersionFeaturesBadPathsAndMissingDependency() throws {
        let root = try temporaryDirectory(), original = try makeProject(root: root)
        let archive = root.appendingPathComponent("hostile.coverproject")
        var future = ArchiveManifest(project: original, mode: .full); future.schemaVersion = 2
        var unsupported = ArchiveManifest(project: original, mode: .full); unsupported.featureFlags.append("unknown-edit-operation")
        var path = ArchiveManifest(project: original, mode: .full); path.project.assets[0].path = "../private.wav"
        var missing = ArchiveManifest(project: original, mode: .full); missing.project.assets.removeLast()
        for manifest in [future, unsupported, path, missing] {
            try writeEnvelope(manifest, to: archive)
            XCTAssertThrowsError(try ProjectArchive.inspect(archive))
        }
    }

    func testRestoreKeepBothPreservesExistingRevisionAndOriginalMedia() async throws {
        let scratch = try temporaryDirectory(), source = scratch.appendingPathComponent("source")
        var incoming = try makeProject(root: source)
        let archive = scratch.appendingPathComponent("incoming.coverproject")
        try ProjectArchive.create(project: incoming, root: source, destination: archive, mode: .full)
        let repo = try ProjectRepository(root: scratch.appendingPathComponent("library"))
        let first = try await repo.restore(archive: archive)
        incoming = first; incoming.touch(); incoming.song.title = "本地修改"
        try await repo.save(incoming)
        let second = try await repo.restore(archive: archive, keepBoth: true)
        XCTAssertNotEqual(first.id, second.id); XCTAssertEqual(second.originalProjectID, first.id)
        let all = try await repo.loadAll()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first(where: { $0.id == first.id })?.song.title, "本地修改")
        XCTAssertTrue(second.backups.contains { $0.level == .restoreVerified })
        for asset in first.assets { XCTAssertEqual(try FileIntegrity.sha256(repo.directory(first.id).appendingPathComponent(asset.path)), asset.sha256) }
    }

    func testReplacementRetainsSafetyCopyAndDuplicateResetsRevision() async throws {
        let scratch = try temporaryDirectory(), source = scratch.appendingPathComponent("source")
        let project = try makeProject(root: source), archive = scratch.appendingPathComponent("project.coverproject")
        try ProjectArchive.create(project: project, root: source, destination: archive, mode: .full)
        let library = scratch.appendingPathComponent("library"), repo = try ProjectRepository(root: library)
        var local = try await repo.restore(archive: archive); local.revision = 5; local.song.title = "本地修改"
        try await repo.save(local)
        let duplicate = try await repo.duplicate(local)
        XCTAssertEqual(duplicate.revision, 1); XCTAssertNotEqual(duplicate.id, local.id)
        _ = try await repo.restore(archive: archive, keepBoth: false)
        let safety = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".safety-") })
        let saved = try JSONDecoder().decode(StudioProject.self, from: Data(contentsOf: safety.appendingPathComponent("project.json")))
        XCTAssertEqual(saved.revision, 5); XCTAssertEqual(saved.song.title, "本地修改")
        let all = try await repo.loadAll(); XCTAssertEqual(all.count, 2)
    }

    func testInterruptedReplacementRecoversOldProjectBeforeLoadingLibrary() async throws {
        let scratch = try temporaryDirectory(), repo = try ProjectRepository(root: scratch)
        let source = try temporaryDirectory(), project = try makeProject(root: source)
        let archive = source.appendingPathComponent("project.coverproject")
        try ProjectArchive.create(project: project, root: source, destination: archive, mode: .full)
        _ = try await repo.restore(archive: archive)
        let safetyName = ".safety-" + UUID().uuidString
        try FileManager.default.moveItem(at: repo.directory(project.id), to: scratch.appendingPathComponent(safetyName))
        let journal: [String: Any] = ["projectID": project.id.uuidString, "safetyDirectory": safetyName]
        try JSONSerialization.data(withJSONObject: journal).write(to: scratch.appendingPathComponent(".restore-transaction.json"))
        let recovered = try ProjectRepository(root: scratch)
        let all = try await recovered.loadAll(); XCTAssertEqual(all.map(\.id), [project.id])
    }

    func testUnexportedArchiveCannotAuthorizeRelease() async throws {
        let root = try temporaryDirectory(), repo = try ProjectRepository(root: root)
        var project = try makeProject(root: repo.directory(UUID()))
        project.backups = [.init(archiveID: UUID(), revision: project.revision, level: .archivePrepared, note: "local only")]
        do {
            _ = try await repo.releaseLocal(project, confirmedRevision: project.revision)
            XCTFail("A temporary local archive cannot authorize deleting originals")
        } catch { XCTAssertTrue(error is StudioError) }
    }

    func testTamperedRestoreCannotModifyAnExistingProject() async throws {
        let scratch = try temporaryDirectory(), source = scratch.appendingPathComponent("source")
        let project = try makeProject(root: source), archive = scratch.appendingPathComponent("project.coverproject")
        try ProjectArchive.create(project: project, root: source, destination: archive, mode: .full)
        let repo = try ProjectRepository(root: scratch.appendingPathComponent("library"))
        var local = try await repo.restore(archive: archive); local.touch(); local.song.title = "必须保留"
        try await repo.save(local)
        var tampered = try Data(contentsOf: archive); tampered[tampered.count - 1] ^= 1; try tampered.write(to: archive)
        do { _ = try await repo.restore(archive: archive, keepBoth: false); XCTFail("Tampered archive accepted") } catch {}
        let all = try await repo.loadAll(); XCTAssertEqual(all.count, 1); XCTAssertEqual(all[0].song.title, "必须保留")
        for asset in local.assets { XCTAssertEqual(try FileIntegrity.sha256(repo.directory(local.id).appendingPathComponent(asset.path)), asset.sha256) }
    }

    func testRecordingTransitionsAndDynamicDiskBudget() {
        XCTAssertTrue(RecordingState.recording.canTransition(to: .interrupted))
        XCTAssertTrue(RecordingState.interrupted.canTransition(to: .finalizing))
        XCTAssertTrue(RecordingState.countdown.canTransition(to: .ready))
        XCTAssertTrue(RecordingState.interrupted.canTransition(to: .preflight))
        XCTAssertTrue(RecordingState.ready.canTransition(to: .idle))
        XCTAssertFalse(RecordingState.idle.canTransition(to: .recording))
        XCTAssertFalse(RecordingState.saved.canTransition(to: .recording))
        let audio = DiskBudget(bytesPerSecond: 200_000), video = DiskBudget(bytesPerSecond: 2_000_000)
        XCTAssertGreaterThan(video.stopBytes, audio.stopBytes)
        XCTAssertTrue(audio.shouldStop(available: audio.stopBytes))
        XCTAssertFalse(audio.shouldStop(available: audio.warningBytes))
        XCTAssertEqual(DiskBudget(bytesPerSecond: .infinity).stopBytes, .max)
        XCTAssertEqual(DiskBudget(bytesPerSecond: .nan).stopBytes, .max)
        XCTAssertEqual(DiskBudget(bytesPerSecond: 2_000_000, finalizationBytes: .max).stopBytes, .max)
    }
    func testUnrepresentableMediaTimeAndAudioPresetRoundTrip() throws {
        XCTAssertEqual(MediaTime(seconds: .nan).timescale, 0)
        XCTAssertEqual(MediaTime(seconds: .infinity).timescale, 0)
        XCTAssertEqual(MediaTime(seconds: 1e100).timescale, 0)
        XCTAssertEqual(MediaTime(seconds: 1.25).seconds, 1.25)
        var preset = ExportPreset(); preset.audioFormat = .wav; preset.variants = [.mixAudio, .dryVocal]
        let data = try FileIntegrity.encoder().encode(preset)
        XCTAssertEqual(try JSONDecoder().decode(ExportPreset.self, from: data), preset)
    }
    func testCaptureOrderSurvivesHostClockResetAndOldPackages() throws {
        let root = try temporaryDirectory(), vocal = try asset("recording.wav", root: root)
        var first = segment(vocal, start: 0, duration: 10); first.sequence = 0; first.hostStart = .init(seconds: 5000)
        var resumed = segment(vocal, start: 7, duration: 5); resumed.sequence = 1; resumed.hostStart = .init(seconds: 20)
        XCTAssertEqual(Timeline.orderedSegments([resumed, first]).map(\.id), [first.id, resumed.id])
        var take = Take(name: "recovered", kind: .audio, arrangementID: UUID(), semitones: -2)
        take.segments = [resumed, first]
        XCTAssertEqual(Timeline.regions(take: take, edit: EditGraph()).map(\.duration), [7, 5])
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: FileIntegrity.encoder().encode(first)) as? [String: Any])
        legacy.removeValue(forKey: "sequence")
        let old = try JSONDecoder().decode(RecordingSegment.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.sequence)
        XCTAssertEqual(Timeline.orderedSegments([old, resumed]).map(\.id), [first.id, resumed.id])
    }
    func testSubtitleIntervalsRespectTrimOffsetAndExplicitDisplayRange() throws {
        var lyrics = Lyrics()
        lyrics.lines = [.init(text: "Before", time: 0), .init(text: "Current", time: 4), .init(text: "Future", time: 8)]
        lyrics.offset = 1
        var edit = EditGraph(); edit.trimStart = 3; edit.subtitleStart = 4; edit.subtitleEnd = 10
        let cues = try Timeline.subtitleCues(lyrics: lyrics, edit: edit, duration: 8)
        XCTAssertEqual(cues.map(\.text), ["Before", "Current", "Future"])
        XCTAssertEqual(cues.map(\.start), [1, 2, 6])
        XCTAssertEqual(cues.map(\.end), [2, 6, 7])
        XCTAssertFalse(cues.contains { $0.start <= 0.5 && 0.5 < $0.end })
        XCTAssertEqual(cues.filter { $0.start <= 2 && 2 < $0.end }.map(\.text), ["Current"])
        XCTAssertFalse(cues.contains { $0.start <= 7 && 7 < $0.end })
        XCTAssertThrowsError(try Timeline.subtitleCues(lyrics: Lyrics(), edit: edit, duration: 8))
    }
}

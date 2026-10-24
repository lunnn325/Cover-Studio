import Foundation
import XCTest
@testable import CoverCore

/// File-preservation fixtures, not playable or repaired media.
final class RecoveryFilesTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RecoveryFilesTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func write(_ data: Data, path: String, root: URL) throws {
        let target = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
    }
    private func fixture(_ repository: ProjectRepository) async throws -> StudioProject {
        let staging = try directory()
        var assets: [MediaAsset] = []
        for (name, role) in [("backing.wav", AssetRole.backing), ("vocal.wav", .vocal)] {
            let path = "media/" + name, data = Data(("fixture " + name).utf8)
            try write(data, path: path, root: staging)
            assets.append(MediaAsset(path: path, role: role, bytes: Int64(data.count), sha256: try FileIntegrity.sha256(staging.appendingPathComponent(path)), duration: .init(seconds: 2)))
        }
        let arrangement = Arrangement(sourceAssetID: assets[0].id, isBacking: true)
        var project = StudioProject(song: .init(title: "Recovery fixture"), arrangement: arrangement, assets: assets, sourceDeviceID: "test")
        var take = Take(name: "Saved Take", kind: .audio, arrangementID: arrangement.id, semitones: 0)
        take.segments = [.init(vocalAssetID: assets[1].id, videoAssetID: nil, songStart: .init(seconds: 0), hostStart: .init(seconds: 10),
            duration: .init(seconds: 2), audioFirstPTS: .init(seconds: 10), videoFirstPTS: nil, playbackHostTime: 0, inputLatency: 0, outputLatency: 0, route: "fixture")]
        project.takes = [take]; project.edit.selectedTakeID = take.id; project.touch(); project.touch()
        try FileManager.default.moveItem(at: staging, to: repository.directory(project.id))
        try await repository.save(project)
        return project
    }
    func testPendingJournalBlocksNewTakeAndRequiresItsOriginalOwner() async throws {
        let repository = try ProjectRepository(root: try directory()), project = try await fixture(repository)
        let source = repository.directory(project.id), journal = source.appendingPathComponent("recording.json")
        let indexBefore = try Data(contentsOf: source.appendingPathComponent("project.json"))
        let owner = project.takes[0]
        let next = Take(name: "Next", kind: .audio, arrangementID: project.arrangementID, semitones: 0)
        for data in [try FileIntegrity.encoder().encode(owner), Data("interrupted incomplete log".utf8)] {
            try data.write(to: journal)
            do { _ = try await repository.beginRecordingTake(project, take: next); XCTFail("Overwrote a pending log") } catch {}
            XCTAssertEqual(try Data(contentsOf: journal), data)
            XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("project.json")), indexBefore)
        }
        try FileIntegrity.encoder().encode(owner).write(to: journal)
        try await repository.validateRecordingStart(project, recovering: owner.id)
        do { try await repository.completeRecordingTake(project, takeID: next.id); XCTFail("Cleared another Take's log") } catch {}
        var mismatched = owner; mismatched.semitones = 1
        let altered = try FileIntegrity.encoder().encode(mismatched)
        try altered.write(to: journal)
        do { try await repository.validateRecordingStart(project, recovering: owner.id); XCTFail("Accepted changed capture settings") } catch {}
        XCTAssertEqual(try Data(contentsOf: journal), altered)
    }
    func testNewTakeJournalPersistsUntilOwnedNonemptyTakeIsCommitted() async throws {
        let repository = try ProjectRepository(root: try directory()), project = try await fixture(repository)
        let source = repository.directory(project.id), journal = source.appendingPathComponent("recording.json")
        let originalHash = try FileIntegrity.sha256(source.appendingPathComponent(project.assets[1].path))
        let take = Take(name: "Next", kind: .audio, arrangementID: project.arrangementID, semitones: 0)
        var updated = try await repository.beginRecordingTake(project, take: take)
        XCTAssertEqual(updated.takes.count, project.takes.count + 1)
        XCTAssertEqual(updated.edit.selectedTakeID, take.id)
        XCTAssertEqual(try JSONDecoder().decode(Take.self, from: Data(contentsOf: journal)), take)
        try await repository.validateRecordingStart(updated, recovering: take.id)
        do { try await repository.completeRecordingTake(updated, takeID: take.id); XCTFail("Empty Take marked complete") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
        updated.takes[updated.takes.count - 1].segments = project.takes[0].segments
        updated.touch(); try await repository.save(updated)
        try await repository.completeRecordingTake(updated, takeID: take.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertEqual(try FileIntegrity.sha256(source.appendingPathComponent(project.assets[1].path)), originalHash)
        do { try await repository.validateRecordingStart(updated, recovering: take.id); XCTFail("Resumed a closed log") } catch {}
        try await repository.validateRecordingStart(updated)
    }
    func testTakeCreationRejectsStaleSnapshotAndJournalSymlinkWithoutChangingBytes() async throws {
        let repository = try ProjectRepository(root: try directory()), project = try await fixture(repository)
        let source = repository.directory(project.id), journal = source.appendingPathComponent("recording.json")
        var current = project; current.song.title = "New edit"; current.touch(); try await repository.save(current)
        let take = Take(name: "Next", kind: .audio, arrangementID: project.arrangementID, semitones: 0)
        do { _ = try await repository.beginRecordingTake(project, take: take); XCTFail("Used stale project") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        let outside = try directory().appendingPathComponent("keep.json"), bytes = Data("external original".utf8)
        try bytes.write(to: outside)
        try FileManager.default.createSymbolicLink(at: journal, withDestinationURL: outside)
        do { _ = try await repository.beginRecordingTake(current, take: take); XCTFail("Followed a journal symlink") } catch {}
        XCTAssertEqual(try Data(contentsOf: outside), bytes)
        let saved = try await repository.loadAll()
        XCTAssertEqual(saved.first?.takes, project.takes)
    }
    func testFailedTakeIndexCommitRetainsLogAndPreviousSourceIndex() async throws {
        let repository = try ProjectRepository(root: try directory()), project = try await fixture(repository)
        let source = repository.directory(project.id), index = source.appendingPathComponent("project.json")
        let before = try Data(contentsOf: index)
        // Force a real filesystem write failure at the safety-index destination.
        try FileManager.default.createDirectory(at: source.appendingPathComponent("project.previous.json"), withIntermediateDirectories: false)
        let take = Take(name: "Not yet committed", kind: .audio, arrangementID: project.arrangementID, semitones: 0)
        do { _ = try await repository.beginRecordingTake(project, take: take); XCTFail("Unexpected index commit") } catch {}
        XCTAssertEqual(try Data(contentsOf: index), before)
        let retained = try JSONDecoder().decode(Take.self, from: Data(contentsOf: source.appendingPathComponent("recording.json")))
        XCTAssertEqual(retained.id, take.id)
        for asset in project.assets { XCTAssertEqual(try FileIntegrity.sha256(source.appendingPathComponent(asset.path)), asset.sha256) }
    }
    func testDuplicatePreservesUnindexedFilesAndHistoryButOmitsRebuildableCache() async throws {
        let repository = try ProjectRepository(root: try directory()), project = try await fixture(repository)
        let source = repository.directory(project.id)
        let extra = ["media/unfinished.mov", "exports/old-output.mp4", "recording.json"]
        for path in extra { try write(Data(("unindexed " + path).utf8), path: path, root: source) }
        try write(Data(repeating: 7, count: 512 * 1024), path: "cache/preview/file.caf", root: source)
        let inventory = try ProjectFiles.inventory(root: source, excluding: ["cache"])
        XCTAssertTrue(Set(extra).isSubset(of: Set(inventory.map(\.path))))
        XCTAssertFalse(inventory.contains { $0.path.hasPrefix("cache/") })
        let copy = try await repository.duplicate(project), target = repository.directory(copy.id)
        XCTAssertNotEqual(copy.id, project.id); XCTAssertEqual(copy.revision, 1)
        XCTAssertEqual(copy.takes, project.takes)
        for path in extra {
            XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(path)), try Data(contentsOf: target.appendingPathComponent(path)))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("cache").path))
        let previous = try JSONDecoder().decode(StudioProject.self, from: Data(contentsOf: target.appendingPathComponent("project.previous.json")))
        XCTAssertEqual(previous.id, copy.id); XCTAssertEqual(previous.revision, 1)
        for asset in project.assets { XCTAssertEqual(try FileIntegrity.sha256(target.appendingPathComponent(asset.path)), asset.sha256) }
    }
    func testCopyHashFailureRetainsInspectableStagingAndNeverChangesOriginalIndex() async throws {
        let repository = try ProjectRepository(root: try directory()), project = try await fixture(repository)
        let source = repository.directory(project.id), vocal = source.appendingPathComponent(project.assets[1].path)
        let index = try Data(contentsOf: source.appendingPathComponent("project.json"))
        var altered = try Data(contentsOf: vocal); altered[0] ^= 1; try altered.write(to: vocal)
        do { _ = try await repository.duplicate(project); XCTFail("Changed source hash must reject the copy") } catch { XCTAssertTrue(error is StudioError) }
        XCTAssertEqual(try Data(contentsOf: vocal), altered)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("project.json")), index)
        let retained = try FileManager.default.contentsOfDirectory(at: repository.root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".duplicate-") }
        XCTAssertEqual(retained.count, 1)
        XCTAssertTrue(ProjectFiles.isRetainedDirectory(try XCTUnwrap(retained.first).lastPathComponent))
        XCTAssertFalse(ProjectFiles.isRetainedDirectory(".duplicate-../outside"))
        let all = try await repository.loadAll(); XCTAssertEqual(all.map(\.id), [project.id])
    }
    func testEndingPendingProtectsTailAndJournalInFullArchiveWithoutInventingTakeTiming() async throws {
        let repository = try ProjectRepository(root: try directory()), project = try await fixture(repository)
        let root = repository.directory(project.id), tail = Data("unfinalized bytes".utf8)
        try write(tail, path: "media/tail.mov", root: root)
        let journal = try FileIntegrity.encoder().encode(try XCTUnwrap(project.takes.first))
        try write(journal, path: "recording.json", root: root)
        let closed = try await repository.closePendingRecording(project, takeID: project.takes[0].id)
        XCTAssertEqual(closed.takes, project.takes); XCTAssertEqual(closed.edit, project.edit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("recording.json").path))
        let extra = closed.assets.filter { !Set(project.assets.map(\.id)).contains($0.id) }
        XCTAssertEqual(extra.count, 2); XCTAssertTrue(extra.allSatisfy { $0.role == .source && $0.duration.value == 0 })
        let retainedJournal = try XCTUnwrap(extra.first { $0.path.hasSuffix(".json") })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(retainedJournal.path)), journal)
        let archive = try directory().appendingPathComponent("protected.coverproject")
        try ProjectArchive.create(project: closed, root: root, destination: archive, mode: .full)
        let restoredRepository = try ProjectRepository(root: try directory())
        let restored = try await restoredRepository.restore(archive: archive)
        XCTAssertEqual(try Data(contentsOf: restoredRepository.directory(restored.id).appendingPathComponent("media/tail.mov")), tail)
        XCTAssertEqual(restored.takes, project.takes)
        let slim = try ProjectRules.backupProject(closed, mode: .slim)
        XCTAssertFalse(slim.assets.contains { $0.path == "media/tail.mov" })
    }
    func testUnidentifiedJournalCanBePreservedButCannotCloseADifferentKnownTake() async throws {
        let repository = try ProjectRepository(root: try directory()), project = try await fixture(repository)
        let root = repository.directory(project.id), invalid = Data("incomplete journal".utf8)
        try write(invalid, path: "recording.json", root: root)
        let closed = try await repository.closePendingRecording(project, takeID: nil)
        XCTAssertEqual(closed.takes, project.takes)
        let log = try XCTUnwrap(closed.assets.first { $0.path.hasSuffix(".json") })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(log.path)), invalid)
        try write(FileIntegrity.encoder().encode(project.takes[0]), path: "recording.json", root: root)
        do { _ = try await repository.closePendingRecording(closed, takeID: UUID()); XCTFail("Wrong Take must not close a journal") } catch {}
        do { _ = try await repository.closePendingRecording(closed, takeID: nil); XCTFail("Known Take must not be closed as unidentified") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("recording.json").path))
    }
    func testRawManagementRejectsReferencesPendingDeletionAndSymlinkEscapes() async throws {
        let repository = try ProjectRepository(root: try directory()), project = try await fixture(repository)
        let root = repository.directory(project.id)
        try write(Data("orphan bytes".utf8), path: "media/orphan.dat", root: root)
        do { _ = try await repository.removeUnclaimedMedia(project, path: project.assets[1].path); XCTFail("Referenced original cannot be removed") } catch {}
        let adopted = try await repository.adoptUnregistered(project, paths: ["media/orphan.dat"])
        XCTAssertEqual(adopted.assets.count, project.assets.count + 1)
        try write(FileIntegrity.encoder().encode(project.takes[0]), path: "recording.json", root: root)
        do { _ = try await repository.removeUnclaimedMedia(adopted, path: "media/orphan.dat"); XCTFail("Pending recording must protect its originals") } catch {}
        try FileManager.default.removeItem(at: root.appendingPathComponent("recording.json"))
        let removed = try await repository.removeUnclaimedMedia(adopted, path: "media/orphan.dat")
        XCTAssertEqual(removed.assets.count, project.assets.count)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("media/orphan.dat").path))
        for asset in project.assets { XCTAssertEqual(try FileIntegrity.sha256(root.appendingPathComponent(asset.path)), asset.sha256) }
        let outside = try directory().appendingPathComponent("outside.dat"); try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("media/link.dat"), withDestinationURL: outside)
        XCTAssertThrowsError(try ProjectFiles.url("media/link.dat", root: root))
        do { _ = try await repository.adoptUnregistered(removed, paths: ["media/link.dat"]); XCTFail("Symlink cannot be adopted") } catch {}
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
    }
}

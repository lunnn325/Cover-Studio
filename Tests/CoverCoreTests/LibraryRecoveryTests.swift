import Foundation
import XCTest
@testable import CoverCore

/// Filesystem and metadata recovery only; these fixture bytes are not playable media.
final class LibraryRecoveryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryRecoveryTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func fixture(_ repository: ProjectRepository, title: String = "Fixture") async throws -> StudioProject {
        let id = UUID(), root = try await repository.makeDirectory(id)
        let url = root.appendingPathComponent("media/backing.wav"), bytes = Data("unchanged original fixture".utf8)
        try bytes.write(to: url)
        let asset = MediaAsset(path: "media/backing.wav", role: .backing, bytes: Int64(bytes.count), sha256: try FileIntegrity.sha256(url), duration: .init(seconds: 2))
        let arrangement = Arrangement(sourceAssetID: asset.id, isBacking: true)
        var project = StudioProject(song: .init(title: title), arrangement: arrangement, assets: [asset], sourceDeviceID: "test")
        project.id = id
        try await repository.save(project)
        return project
    }
    private func damage(_ project: StudioProject, repository: ProjectRepository) async throws -> StudioProject {
        var latest = project; latest.song.title += " latest"; latest.touch()
        try await repository.save(latest)
        try Data("truncated current JSON".utf8).write(to: repository.directory(project.id).appendingPathComponent("project.json"))
        return latest
    }
    func testBadAndMissingIndicesAreVisibleWithoutBlockingHealthyProjects() async throws {
        let repository = try ProjectRepository(root: try directory())
        let healthy = try await fixture(repository, title: "Healthy"), bad = try await fixture(repository, title: "Bad")
        _ = try await damage(bad, repository: repository)
        let orphanID = UUID(); _ = try await repository.makeDirectory(orphanID)
        let before = try Data(contentsOf: repository.directory(bad.id).appendingPathComponent("project.json"))
        let scan = try await repository.scanLibrary()
        XCTAssertEqual(scan.projects.map(\.id), [healthy.id])
        XCTAssertEqual(Set(scan.issues.compactMap(\.projectID)), [bad.id, orphanID])
        XCTAssertEqual(try Data(contentsOf: repository.directory(bad.id).appendingPathComponent("project.json")), before)
        do { _ = try await repository.loadAll(); XCTFail("Strict caller silently ignored problems") } catch {}
    }
    func testPreviousIndexRecoveryCopiesAllOriginalsWithoutInventingMissingTakes() async throws {
        let repository = try ProjectRepository(root: try directory()), original = try await fixture(repository)
        let latest = try await damage(original, repository: repository), source = repository.directory(original.id)
        let tail = Data("unindexed unfinished capture".utf8), output = Data("old unregistered output".utf8)
        try tail.write(to: source.appendingPathComponent("media/tail.mov"))
        try FileManager.default.createDirectory(at: source.appendingPathComponent("exports"), withIntermediateDirectories: true)
        try output.write(to: source.appendingPathComponent("exports/old.mp4"))
        let unsavedTake = Take(name: "Not in previous index", kind: .audio, arrangementID: original.arrangementID, semitones: 0)
        try FileIntegrity.encoder().encode(unsavedTake).write(to: source.appendingPathComponent("recording.json"))
        try FileManager.default.createDirectory(at: source.appendingPathComponent("cache"), withIntermediateDirectories: true)
        try Data(repeating: 9, count: 1024).write(to: source.appendingPathComponent("cache/rebuildable.caf"))
        let before = try Data(contentsOf: source.appendingPathComponent("project.json"))
        let previous = try Data(contentsOf: source.appendingPathComponent("project.previous.json"))
        let candidate = try await repository.inspectPreviousIndex(original.id.uuidString)
        XCTAssertEqual(candidate.title, original.song.title); XCTAssertEqual(candidate.revision, original.revision)
        let recovered = try await repository.recoverPreviousIndex(candidate), target = repository.directory(recovered.id)
        XCTAssertNotEqual(recovered.id, original.id); XCTAssertEqual(recovered.originalProjectID, original.id)
        XCTAssertEqual(recovered.takes, original.takes); XCTAssertTrue(recovered.backups.isEmpty)
        XCTAssertNotEqual(recovered.song.title, latest.song.title)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("project.json")), before)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("project.previous.json")), previous)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("media/tail.mov")), tail)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("exports/old.mp4")), output)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("recording.json")), try FileIntegrity.encoder().encode(unsavedTake))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("cache").path))
        XCTAssertEqual(try JSONDecoder().decode(StudioProject.self, from: Data(contentsOf: target.appendingPathComponent("project.previous.json"))).id, recovered.id)
        XCTAssertTrue(recovered.assets.contains { $0.path == "media/tail.mov" && $0.role == .source && $0.duration.seconds == 0 })
        let metadata = recovered.assets.filter { $0.path.hasPrefix("media/recovery-index-") }
        XCTAssertEqual(Set(try metadata.map { try Data(contentsOf: target.appendingPathComponent($0.path)) }), Set([before, previous]))
        let archive = try directory().appendingPathComponent("protected.coverproject")
        try ProjectArchive.create(project: recovered, root: target, destination: archive, mode: .full)
        let manifest = try ProjectArchive.inspect(archive)
        XCTAssertTrue(manifest.project.assets.contains { $0.path == "media/tail.mov" })
        let scan = try await repository.scanLibrary()
        XCTAssertEqual(scan.projects.map(\.id), [recovered.id]); XCTAssertEqual(scan.issues.map(\.projectID), [original.id])
    }
    func testMissingCurrentIndexCanRecoverButHealthyCurrentIsNeverRolledBack() async throws {
        let repository = try ProjectRepository(root: try directory()), original = try await fixture(repository)
        var latest = original; latest.touch(); try await repository.save(latest)
        do { _ = try await repository.inspectPreviousIndex(original.id.uuidString); XCTFail("Offered rollback of healthy index") } catch {}
        try FileManager.default.removeItem(at: repository.directory(original.id).appendingPathComponent("project.json"))
        let candidate = try await repository.inspectPreviousIndex(original.id.uuidString)
        XCTAssertNil(candidate.currentIndexHash)
        let recovered = try await repository.recoverPreviousIndex(candidate)
        XCTAssertEqual(recovered.assets.count, original.assets.count + 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.directory(original.id).appendingPathComponent("project.json").path))
    }
    func testChangedCandidateAndMissingOrTamperedMediaCannotPublishRecovery() async throws {
        let repository = try ProjectRepository(root: try directory()), original = try await fixture(repository)
        _ = try await damage(original, repository: repository)
        let candidate = try await repository.inspectPreviousIndex(original.id.uuidString), root = repository.directory(original.id)
        let changed = Data("different invalid current index".utf8)
        try changed.write(to: root.appendingPathComponent("project.json"))
        do { _ = try await repository.recoverPreviousIndex(candidate); XCTFail("Accepted stale candidate") } catch {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("project.json")), changed)
        let asset = root.appendingPathComponent(original.assets[0].path)
        try Data(repeating: 0, count: Int(original.assets[0].bytes)).write(to: asset)
        do { _ = try await repository.inspectPreviousIndex(original.id.uuidString); XCTFail("Accepted corrupt source") } catch {}
        try FileManager.default.removeItem(at: asset)
        do { _ = try await repository.inspectPreviousIndex(original.id.uuidString); XCTFail("Accepted missing source") } catch {}
        let scan = try await repository.scanLibrary(); XCTAssertTrue(scan.projects.isEmpty); XCTAssertEqual(scan.issues.count, 1)
    }
    func testWrongIdentityAndSymlinkCannotBeReadAsRecoverySources() async throws {
        let repository = try ProjectRepository(root: try directory()), original = try await fixture(repository)
        let root = repository.directory(original.id)
        var wrong = original; wrong.id = UUID()
        try FileIntegrity.encoder().encode(wrong).write(to: root.appendingPathComponent("project.json"))
        let scan = try await repository.scanLibrary(); XCTAssertTrue(scan.projects.isEmpty); XCTAssertEqual(scan.issues.count, 1)
        let outside = try directory().appendingPathComponent("outside.json"), bytes = Data("outside bytes".utf8)
        try bytes.write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("project.previous.json"), withDestinationURL: outside)
        do { _ = try await repository.inspectPreviousIndex(original.id.uuidString); XCTFail("Read a symlink") } catch {}
        do { _ = try await repository.libraryIssueFileURL(original.id.uuidString, path: "../outside.json"); XCTFail("Read outside library") } catch {}
        XCTAssertEqual(try Data(contentsOf: outside), bytes)
        let alias = UUID().uuidString
        try FileManager.default.createSymbolicLink(at: repository.root.appendingPathComponent(alias), withDestinationURL: try directory())
        let next = try await repository.scanLibrary(); XCTAssertEqual(next.issues.count, 2)
    }
    func testExternalArchiveRestoreStillWorksBesideDamagedDirectory() async throws {
        let repository = try ProjectRepository(root: try directory()), original = try await fixture(repository)
        let archive = try directory().appendingPathComponent("valid.coverproject")
        try ProjectArchive.create(project: original, root: repository.directory(original.id), destination: archive, mode: .full)
        _ = try await damage(original, repository: repository)
        let restored = try await repository.restore(archive: archive, keepBoth: true)
        let scan = try await repository.scanLibrary()
        XCTAssertNotEqual(restored.id, original.id)
        XCTAssertEqual(scan.projects.map(\.id), [restored.id]); XCTAssertEqual(scan.issues.map(\.projectID), [original.id])
        XCTAssertEqual(try FileIntegrity.sha256(repository.directory(restored.id).appendingPathComponent(original.assets[0].path)), original.assets[0].sha256)
    }
}

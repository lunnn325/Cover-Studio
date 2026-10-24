import Foundation
import XCTest
@testable import CoverCore

/// Startup metadata and filesystem integrity, not UI or device recovery evidence.
final class RepositoryStartupTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RepositoryStartupTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func fixture(_ repository: ProjectRepository) async throws -> StudioProject {
        let id = UUID(), root = try await repository.makeDirectory(id), data = Data("original startup fixture bytes".utf8)
        let url = root.appendingPathComponent("media/backing.wav"); try data.write(to: url)
        let asset = MediaAsset(path: "media/backing.wav", role: .backing, bytes: Int64(data.count), sha256: try FileIntegrity.sha256(url), duration: .init(seconds: 2))
        let arrangement = Arrangement(sourceAssetID: asset.id, isBacking: true)
        var project = StudioProject(song: .init(title: "Startup fixture"), arrangement: arrangement, assets: [asset], sourceDeviceID: "test")
        project.id = id; try await repository.save(project)
        return project
    }
    private func journal(_ projectID: UUID, safety: String, root: URL) throws -> Data {
        let bytes = try JSONSerialization.data(withJSONObject: ["projectID": projectID.uuidString, "safetyDirectory": safety])
        try bytes.write(to: root.appendingPathComponent(".restore-transaction.json"))
        return bytes
    }
    func testCorruptMarkerCanBeExplicitlyPreservedWithoutTouchingProjects() async throws {
        let root = try directory(), repository = try ProjectRepository(root: root), project = try await fixture(repository)
        let before = try Data(contentsOf: repository.directory(project.id).appendingPathComponent("project.json"))
        let invalid = Data("interrupted corrupt root transaction".utf8)
        let marker = root.appendingPathComponent(".restore-transaction.json"); try invalid.write(to: marker)
        XCTAssertThrowsError(try ProjectRepository(root: root))
        XCTAssertEqual(try Data(contentsOf: marker), invalid)
        let pending = try XCTUnwrap(RepositoryStartup.pending(root: root))
        let retained = try RepositoryStartup.preservePending(root: root, expected: pending)
        XCTAssertEqual(try Data(contentsOf: retained), invalid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try Data(contentsOf: repository.directory(project.id).appendingPathComponent("project.json")), before)
        let reopened = try ProjectRepository(root: root), scan = try await reopened.scanLibrary()
        XCTAssertEqual(scan.projects.map(\.id), [project.id])
        let logs = try RepositoryStartup.retainedLogs(root: root); XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(try Data(contentsOf: RepositoryStartup.retainedLogURL(logs[0].name, root: root)), invalid)
        XCTAssertEqual(try FileIntegrity.sha256(repository.directory(project.id).appendingPathComponent(project.assets[0].path)), project.assets[0].sha256)
    }
    func testChangedLogAndSymlinkCannotBePreservedAsConfirmedMarker() throws {
        let root = try directory(), marker = root.appendingPathComponent(".restore-transaction.json")
        try Data("first".utf8).write(to: marker)
        let expected = try XCTUnwrap(RepositoryStartup.pending(root: root))
        let changed = Data("changed transaction".utf8); try changed.write(to: marker)
        XCTAssertThrowsError(try RepositoryStartup.preservePending(root: root, expected: expected))
        XCTAssertEqual(try Data(contentsOf: marker), changed)
        XCTAssertTrue(try RepositoryStartup.retainedLogs(root: root).isEmpty)
        try FileManager.default.removeItem(at: marker)
        let outside = try directory().appendingPathComponent("outside.json"), bytes = Data("external original".utf8)
        try bytes.write(to: outside)
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: outside)
        XCTAssertThrowsError(try RepositoryStartup.pending(root: root))
        XCTAssertThrowsError(try RepositoryStartup.preservePending(root: root, expected: expected))
        XCTAssertEqual(try Data(contentsOf: outside), bytes)
        XCTAssertThrowsError(try RepositoryStartup.retainedLogURL("../outside.json", root: root))
    }
    func testOccupiedOrIncompleteTargetRetainsTransactionAndSafetyDirectory() async throws {
        let root = try directory(), repository = try ProjectRepository(root: root), project = try await fixture(repository)
        let safety = ".safety-" + UUID().uuidString, target = repository.directory(project.id)
        try FileManager.default.moveItem(at: target, to: root.appendingPathComponent(safety))
        let occupied = Data("not a project directory".utf8); try occupied.write(to: target)
        let bytes = try journal(project.id, safety: safety, root: root)
        XCTAssertThrowsError(try ProjectRepository(root: root))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".restore-transaction.json")), bytes)
        XCTAssertEqual(try Data(contentsOf: target), occupied)
        let safeAsset = root.appendingPathComponent(safety).appendingPathComponent(project.assets[0].path)
        XCTAssertEqual(try FileIntegrity.sha256(safeAsset), project.assets[0].sha256)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("truncated index".utf8).write(to: target.appendingPathComponent("project.json"))
        XCTAssertThrowsError(try ProjectRepository(root: root))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".restore-transaction.json")), bytes)
        XCTAssertEqual(try FileIntegrity.sha256(safeAsset), project.assets[0].sha256)
    }
    func testUnsafeTransactionCannotMoveExternalDirectory() throws {
        let root = try directory(), outside = try directory(), name = ".safety-" + UUID().uuidString
        let original = outside.appendingPathComponent("keep.bin"), bytes = Data("external bytes".utf8); try bytes.write(to: original)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(name), withDestinationURL: outside)
        let marker = try journal(UUID(), safety: name, root: root)
        XCTAssertThrowsError(try ProjectRepository(root: root))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".restore-transaction.json")), marker)
    }
    func testCommittedTargetKeepsSafetyAndDamagedSafetyOriginalsCanBeExported() async throws {
        let root = try directory(), repository = try ProjectRepository(root: root), project = try await fixture(repository)
        let safety = ".safety-" + UUID().uuidString, safeRoot = root.appendingPathComponent(safety)
        try FileManager.default.copyItem(at: repository.directory(project.id), to: safeRoot)
        _ = try journal(project.id, safety: safety, root: root)
        let reopened = try ProjectRepository(root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".restore-transaction.json").path))
        try Data("corrupt safety index".utf8).write(to: safeRoot.appendingPathComponent("project.json"))
        let files = try await reopened.libraryIssueFiles(safety)
        XCTAssertTrue(files.contains { $0.path == project.assets[0].path })
        let file = try await reopened.libraryIssueFileURL(safety, path: project.assets[0].path)
        XCTAssertEqual(try FileIntegrity.sha256(file), project.assets[0].sha256)
        do { _ = try await reopened.inspectPreviousIndex(safety); XCTFail("Treated retained directory as live project") } catch {}
    }
    func testRootFileAndOversizedLogFailWithoutReplacingExistingBytes() throws {
        let parent = try directory(), root = parent.appendingPathComponent("Projects"), bytes = Data("existing file".utf8)
        try bytes.write(to: root)
        XCTAssertThrowsError(try ProjectRepository(root: root))
        XCTAssertEqual(try Data(contentsOf: root), bytes)
        let validRoot = try directory(), marker = validRoot.appendingPathComponent(".restore-transaction.json")
        try Data(repeating: 1, count: ProjectArchive.maximumManifestBytes + 1).write(to: marker)
        let hash = try FileIntegrity.sha256(marker)
        XCTAssertThrowsError(try RepositoryStartup.pending(root: validRoot))
        XCTAssertThrowsError(try ProjectRepository(root: validRoot))
        XCTAssertEqual(try FileIntegrity.sha256(marker), hash)
    }
}

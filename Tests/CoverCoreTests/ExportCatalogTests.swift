import Foundation
import XCTest
@testable import CoverCore

/// Metadata/filesystem tests only; these fixture bytes are not playable media.
final class ExportCatalogTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExportCatalogTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func file(_ path: String, root: URL, role: AssetRole = .export) throws -> MediaAsset {
        let url = root.appendingPathComponent(path), data = Data(("catalog fixture: " + path).utf8)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return try MediaAsset(path: path, role: role, bytes: Int64(data.count), sha256: FileIntegrity.sha256(url))
    }
    func testCompletedHistorySurvivesQueueReplacementAndDoesNotTrustUntrackedFiles() throws {
        let root = try directory()
        let old = try file("exports/old-mixAudio.wav", root: root)
        let first = ExportJob(variant: .mixAudio, status: "完成", path: old.path)
        // The previous app version wrote only queue.json. Capture it before a new run.
        try FileIntegrity.encoder().encode([first]).write(to: root.appendingPathComponent("exports/queue.json"))
        try ExportCatalog.saveQueue([ExportJob(variant: .mixAudio)], root: root)
        XCTAssertEqual(try ExportCatalog.outputs(root: root).filter(\.completed).map(\.path), [old.path])
        let new = try file("exports/new-mixAudio.wav", root: root)
        let second = ExportJob(variant: .mixAudio, status: "完成", path: new.path)
        try ExportCatalog.saveQueue([second], root: root)
        try ExportCatalog.rememberCompleted([first, second], root: root)
        let orphan = try file("exports/unknown-cleanVideo.mp4", root: root)
        let files = try ExportCatalog.outputs(root: root)
        XCTAssertEqual(Set(files.filter(\.completed).map(\.path)), [old.path, new.path])
        XCTAssertEqual(files.first(where: { $0.path == orphan.path })?.completed, false)
        XCTAssertEqual(try ExportCatalog.queue(root: root), [second])
        XCTAssertEqual(try FileIntegrity.sha256(root.appendingPathComponent(old.path)), old.sha256)
        let other = try directory()
        _ = try file(old.path, root: other)
        XCTAssertFalse(try XCTUnwrap(ExportCatalog.outputs(root: other).first).completed)
    }
    func testRemovingOneHistoricalOutputPreservesSourcesOtherVersionsAndMetadataBoundaries() throws {
        let root = try directory()
        let source = try file("media/original.wav", root: root, role: .vocal)
        let old = try file("exports/old-mixAudio.wav", root: root)
        let new = try file("exports/new-mixAudio.wav", root: root)
        let first = ExportJob(variant: .mixAudio, status: "完成", path: old.path)
        let second = ExportJob(variant: .mixAudio, status: "完成", path: new.path)
        try ExportCatalog.saveQueue([first], root: root)
        try ExportCatalog.saveQueue([second], root: root)
        let queueBefore = try Data(contentsOf: root.appendingPathComponent("exports/queue.json"))
        let historyBefore = try Data(contentsOf: root.appendingPathComponent("exports/history.json"))
        for bad in ["../original.wav", source.path, "exports/queue.json", "exports/history.json", "exports/../media/original.wav"] {
            XCTAssertThrowsError(try ExportCatalog.removeOutput(path: bad, root: root))
        }
        let link = root.appendingPathComponent("exports/link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent(source.path))
        XCTAssertThrowsError(try ExportCatalog.removeOutput(path: "exports/link.wav", root: root))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("exports/queue.json")), queueBefore)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("exports/history.json")), historyBefore)
        try ExportCatalog.removeOutput(path: old.path, root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(old.path).path))
        XCTAssertEqual(try ExportCatalog.queue(root: root), [second])
        XCTAssertEqual(try ExportCatalog.outputs(root: root).map(\.path), [new.path])
        XCTAssertEqual(try FileIntegrity.sha256(root.appendingPathComponent(source.path)), source.sha256)
    }
    func testRestoredOutputsAreKnownButCorruptOrAliasedCatalogCannotBeOverwritten() throws {
        let root = try directory(), exported = try file("exports/custom-name.wav", root: root)
        let restored = try XCTUnwrap(ExportCatalog.outputs(root: root, assets: [exported]).first)
        XCTAssertTrue(restored.completed); XCTAssertNil(restored.variant)
        let history = root.appendingPathComponent("exports/history.json")
        let corrupt = Data("corrupt catalog".utf8); try corrupt.write(to: history)
        XCTAssertThrowsError(try ExportCatalog.rememberCompleted([], root: root))
        XCTAssertThrowsError(try ExportCatalog.outputs(root: root))
        XCTAssertEqual(try Data(contentsOf: history), corrupt)
        XCTAssertThrowsError(try ProjectRules.mediaURL("exports/history.json", root: root))
        XCTAssertTrue(ProjectRules.isExportMetadata("exports/HISTORY.JSON"))
        var collision = exported; collision.path = "exports/history.json"
        let invalid = StudioProject(song: .init(title: "Invalid metadata asset"), arrangement: .init(sourceAssetID: collision.id, isBacking: true), assets: [collision], sourceDeviceID: "test")
        XCTAssertThrowsError(try ProjectRules.validate(invalid))
        try FileManager.default.removeItem(at: history)
        try FileManager.default.createSymbolicLink(at: history, withDestinationURL: root.appendingPathComponent(exported.path))
        XCTAssertThrowsError(try ExportCatalog.rememberCompleted([], root: root))
        XCTAssertEqual(try FileIntegrity.sha256(root.appendingPathComponent(exported.path)), exported.sha256)
    }
    func testBackupCanIncludeEveryCompletedVersionAndRestoreWithoutCatalogSidecars() async throws {
        let root = try directory()
        let backing = try file("media/backing.wav", root: root, role: .backing)
        let first = try file("exports/one-mixAudio.wav", root: root)
        let second = try file("exports/two-cleanVideo.mp4", root: root)
        try ExportCatalog.saveQueue([ExportJob(variant: .mixAudio, status: "完成", path: first.path)], root: root)
        try ExportCatalog.saveQueue([ExportJob(variant: .cleanVideo, status: "完成", path: second.path)], root: root)
        var project = StudioProject(song: .init(title: "Catalog archive"), arrangement: .init(sourceAssetID: backing.id, isBacking: true), assets: [backing], sourceDeviceID: "test")
        let completed = Set(try ExportCatalog.outputs(root: root).filter(\.completed).map(\.path))
        project.assets.append(contentsOf: [first, second].filter { completed.contains($0.path) })
        let archive = root.appendingPathComponent("complete.coverproject")
        try ProjectArchive.create(project: project, root: root, destination: archive, mode: .full, includeExports: true)
        let repository = try ProjectRepository(root: try directory())
        let restored = try await repository.restore(archive: archive)
        let outputs = try ExportCatalog.outputs(root: repository.directory(restored.id), assets: restored.assets)
        XCTAssertEqual(Set(outputs.map(\.path)), [first.path, second.path])
        XCTAssertTrue(outputs.allSatisfy(\.completed))
        XCTAssertFalse(restored.assets.contains { ProjectRules.isExportMetadata($0.path) })
        XCTAssertEqual(try FileIntegrity.sha256(repository.directory(restored.id).appendingPathComponent(backing.path)), backing.sha256)
        let archived = try await repository.releaseLocal(restored, confirmedRevision: restored.revision)
        XCTAssertTrue(archived.archived)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.directory(restored.id).appendingPathComponent(backing.path).path))
        for output in [first, second] {
            XCTAssertEqual(try FileIntegrity.sha256(repository.directory(restored.id).appendingPathComponent(output.path)), output.sha256)
        }
    }
    func testCustomBackupSelectsOutputsButCannotDropAnOutputUsedAsBacking() throws {
        let root = try directory()
        let backing = try file("exports/previous-backing.wav", root: root)
        let version = try file("exports/version-mixAudio.wav", root: root)
        let project = StudioProject(song: .init(title: "Output dependencies"), arrangement: .init(sourceAssetID: backing.id, isBacking: true), assets: [backing, version], sourceDeviceID: "test")
        let required = try ProjectRules.backupProject(project, mode: .custom, includeExports: true, selectedExportPaths: [])
        XCTAssertEqual(required.assets.map(\.id), [backing.id])
        let chosen = try ProjectRules.backupProject(project, mode: .custom, includeExports: true, selectedExportPaths: [version.path])
        XCTAssertEqual(Set(chosen.assets.map(\.id)), [backing.id, version.id])
        XCTAssertThrowsError(try ProjectRules.backupProject(project, mode: .custom, includeExports: true, selectedExportPaths: ["exports/missing.wav"]))
    }
}

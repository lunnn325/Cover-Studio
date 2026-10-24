#if DEBUG && targetEnvironment(simulator)
import Foundation
import CoverCore

/// Isolated metadata/filesystem fixtures for one manually selected native UI check.
/// Never compiled into Release or device builds. No recording or playable Take is fabricated.
enum StartupUITestFixture {
    static func reopenLibrary() throws -> URL {
        let files = FileManager.default
        let report = files.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("StartupUIFixture.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any]
        guard let path = json?["fixtureRoot"] as? String else { throw StudioError("Missing isolated UI fixture.") }
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let temporary = files.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard root.deletingLastPathComponent() == temporary, root.lastPathComponent.hasPrefix("StartupUIFixture-"),
              UUID(uuidString: String(root.lastPathComponent.dropFirst("StartupUIFixture-".count))) != nil else {
            throw StudioError("Refusing to reopen a non-fixture library.")
        }
        return root
    }
    static func makeLibrary() async throws -> URL {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("StartupUIFixture-" + UUID().uuidString)
        let repository = try ProjectRepository(root: root)
        let healthyID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let damagedID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        func project(_ id: UUID, title: String) async throws -> StudioProject {
            let directory = try await repository.makeDirectory(id)
            let data = Data("UI fixture only; not playable audio".utf8), url = directory.appendingPathComponent("media/backing.wav")
            try data.write(to: url)
            let asset = MediaAsset(path: "media/backing.wav", role: .source, bytes: Int64(data.count), sha256: try FileIntegrity.sha256(url), duration: .init(seconds: 2))
            let arrangement = Arrangement(sourceAssetID: asset.id, isBacking: false)
            var model = StudioProject(song: .init(title: title), arrangement: arrangement, assets: [asset], sourceDeviceID: "isolated-ui-fixture")
            model.id = id; try await repository.save(model)
            return model
        }
        _ = try await project(healthyID, title: "启动验证 · 保留作品")
        var damaged = try await project(damagedID, title: "启动验证 · 待恢复作品")
        damaged.song.title += " · 最近修改"; damaged.touch(); try await repository.save(damaged)
        let badIndex = repository.directory(damagedID).appendingPathComponent("project.json")
        try Data("intentionally truncated UI fixture index".utf8).write(to: badIndex)
        let safety = root.appendingPathComponent(".safety-33333333-3333-4333-8333-333333333333")
        try files.createDirectory(at: safety.appendingPathComponent("media"), withIntermediateDirectories: true)
        try Data("intentionally invalid safety index".utf8).write(to: safety.appendingPathComponent("project.json"))
        try Data("retained fixture bytes; not playable audio".utf8).write(to: safety.appendingPathComponent("media/retained-original.wav"))
        let marker = root.appendingPathComponent(".restore-transaction.json")
        try Data("intentionally corrupt isolated startup marker".utf8).write(to: marker)
        let paths = [healthyID.uuidString + "/media/backing.wav", damagedID.uuidString + "/project.json",
                     safety.lastPathComponent + "/media/retained-original.wav", safety.lastPathComponent + "/project.json"]
        var hashes: [String: String] = [:]
        for path in paths { hashes[path] = try FileIntegrity.sha256(root.appendingPathComponent(path)) }
        let report: [String: Any] = ["scope": "Isolated generated metadata/raw-byte fixtures; no hardware or playable media.",
                                     "fixtureRoot": root.path, "originalHashes": hashes, "markerHash": try FileIntegrity.sha256(marker)]
        let documents = files.urls(for: .documentDirectory, in: .userDomainMask).first!
        try files.createDirectory(at: documents, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: documents.appendingPathComponent("StartupUIFixture.json"), options: .atomic)
        return root
    }
}
#endif

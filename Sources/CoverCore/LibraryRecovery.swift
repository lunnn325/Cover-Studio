import Foundation

public struct LibraryIssue: Identifiable, Equatable, Sendable {
    public var id: String { directoryName }
    public let directoryName: String
    public let reason: String
    public var projectID: UUID? { UUID(uuidString: directoryName) }
    public init(directoryName: String, reason: String) { self.directoryName = directoryName; self.reason = reason }
}
public struct LibraryScan: Sendable {
    public let projects: [StudioProject]
    public let issues: [LibraryIssue]
}
public struct IndexRecoveryCandidate: Equatable, Sendable {
    public let directoryName: String
    public let title: String
    public let revision: Int
    public let takeCount: Int
    public let assetCount: Int
    public let currentIndexHash: String?
    public let previousIndexHash: String
}

extension ProjectRepository {
    private func libraryDirectory(_ name: String) throws -> URL {
        guard UUID(uuidString: name) != nil || ProjectFiles.isRetainedDirectory(name) else { throw StudioError("此目录不是受控工程或恢复副本，原文件仍保留。") }
        let directory = try ProjectFiles.url(name, root: root)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw StudioError("工程目录不是受控普通目录，未读取链接目标。") }
        return directory
    }
    private func readLibraryIndex(_ filename: String, directory: URL, identity: UUID) throws -> StudioProject {
        let url = try ProjectFiles.url(filename, root: directory)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true, try FileIntegrity.size(url) <= Int64(ProjectArchive.maximumManifestBytes) else {
            throw StudioError("工程索引不是普通文件或超过安全大小，原文件未修改。")
        }
        let project = try JSONDecoder().decode(StudioProject.self, from: Data(contentsOf: url))
        guard project.id == identity else { throw StudioError("工程索引与目录身份不一致。") }
        try ProjectRules.validate(project)
        return project
    }
    public func scanLibrary() throws -> LibraryScan {
        let files = FileManager.default
        var projects: [StudioProject] = [], issues: [LibraryIssue] = []
        for entry in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where !entry.lastPathComponent.hasPrefix(".") {
            let name = entry.lastPathComponent
            do {
                let directory = try libraryDirectory(name)
                projects.append(try readLibraryIndex("project.json", directory: directory, identity: UUID(uuidString: name)!))
            } catch {
                issues.append(LibraryIssue(directoryName: name, reason: "此工程索引暂不可用。" + error.localizedDescription))
            }
        }
        return LibraryScan(projects: projects.sorted { $0.modifiedAt > $1.modifiedAt }, issues: issues.sorted { $0.directoryName < $1.directoryName })
    }
    public func libraryIssueFiles(_ name: String) throws -> [ProjectFile] {
        try ProjectFiles.inventory(root: libraryDirectory(name), excluding: ["cache"])
    }
    public func libraryIssueFileURL(_ name: String, path: String) throws -> URL {
        let directory = try libraryDirectory(name)
        guard try ProjectFiles.inventory(root: directory, excluding: ["cache"]).contains(where: { $0.path == path }) else {
            throw StudioError("文件已变化，请重新读取原件列表。")
        }
        return try ProjectFiles.url(path, root: directory)
    }
    public func inspectPreviousIndex(_ name: String) throws -> IndexRecoveryCandidate {
        guard let identity = UUID(uuidString: name) else { throw StudioError("安全副本请先另存原件，或校验并导出完整包恢复。") }
        let files = FileManager.default, directory = try libraryDirectory(name)
        guard (try? readLibraryIndex("project.json", directory: directory, identity: identity)) == nil else {
            throw StudioError("当前工程索引已可正常读取，无需回退。请刷新作品库。")
        }
        let previous = try readLibraryIndex("project.previous.json", directory: directory, identity: identity)
        guard !previous.archived else { throw StudioError("上一版仅有归档索引，请从外部工程包恢复源素材。") }
        for asset in previous.assets {
            let url = try ProjectRules.mediaURL(asset.path, root: directory)
            guard try FileIntegrity.size(url) == asset.bytes, try FileIntegrity.sha256(url) == asset.sha256 else {
                throw StudioError("上一版所需素材缺失或哈希不符，不能生成可编辑恢复副本；可先另存原件。")
            }
        }
        let current = try ProjectFiles.url("project.json", root: directory)
        let currentHash: String?
        if files.fileExists(atPath: current.path) {
            guard try current.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw StudioError("损坏索引不是普通文件，请保留原目录并从外部包恢复。") }
            currentHash = try FileIntegrity.sha256(current)
        } else { currentHash = nil }
        return IndexRecoveryCandidate(directoryName: name, title: previous.song.title, revision: previous.revision,
                                      takeCount: previous.takes.count, assetCount: previous.assets.count,
                                      currentIndexHash: currentHash,
                                      previousIndexHash: try FileIntegrity.sha256(ProjectFiles.url("project.previous.json", root: directory)))
    }
    /// Creates a new project. The original directory, bad index and pending log remain intact.
    public func recoverPreviousIndex(_ expected: IndexRecoveryCandidate) throws -> StudioProject {
        guard try inspectPreviousIndex(expected.directoryName) == expected else { throw StudioError("工程或上一版索引已变化，请重新校验后确认。") }
        let files = FileManager.default, source = try libraryDirectory(expected.directoryName)
        var recovered = try readLibraryIndex("project.previous.json", directory: source, identity: UUID(uuidString: expected.directoryName)!)
        let inventory = try ProjectFiles.inventory(root: source, excluding: ["cache", "project.json", "project.previous.json"])
        var total: Int64 = 64 * 1024 * 1024 // Two bounded JSON indices plus staging reserve.
        let previousBytes = try FileIntegrity.size(source.appendingPathComponent("project.previous.json"))
        let currentBytes: Int64
        if expected.currentIndexHash == nil { currentBytes = 0 }
        else { currentBytes = try FileIntegrity.size(source.appendingPathComponent("project.json")) }
        for count in inventory.map(\.bytes) + [previousBytes, currentBytes] {
            let (sum, overflow) = total.addingReportingOverflow(count)
            guard !overflow else { throw StudioError("恢复副本大小无效。") }; total = sum
        }
        guard try FileIntegrity.available(root) > total else { throw StudioError("空间不足以保留原目录并创建恢复副本，请先另存原件或处理空间。") }
        let staging = root.appendingPathComponent(".restore-" + UUID().uuidString)
        try files.createDirectory(at: staging.appendingPathComponent("media"), withIntermediateDirectories: true)
        for file in inventory {
            let input = try ProjectFiles.url(file.path, root: source), output = try ProjectFiles.url(file.path, root: staging)
            try files.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let hash = try FileIntegrity.sha256(input)
            try files.copyItem(at: input, to: output)
            guard try FileIntegrity.size(output) == file.bytes, try FileIntegrity.sha256(output) == hash else {
                throw StudioError("恢复复制期间文件变化，原目录与失败暂存均保留。")
            }
        }
        for (filename, hash) in [("project.json", expected.currentIndexHash), ("project.previous.json", Optional(expected.previousIndexHash))] {
            guard let hash else { continue }
            let output = staging.appendingPathComponent("media/recovery-index-" + UUID().uuidString + ".json")
            try files.copyItem(at: ProjectFiles.url(filename, root: source), to: output)
            guard try FileIntegrity.sha256(output) == hash else { throw StudioError("原索引已变化，恢复副本未提交。") }
        }
        for asset in recovered.assets {
            let url = try ProjectRules.mediaURL(asset.path, root: staging)
            guard try FileIntegrity.size(url) == asset.bytes, try FileIntegrity.sha256(url) == asset.sha256 else {
                throw StudioError("恢复副本素材不完整，未提交，原文件仍保留。")
            }
        }
        recovered.originalProjectID = recovered.originalProjectID ?? recovered.id
        recovered.id = UUID(); recovered.branchID = UUID(); recovered.revision = 1; recovered.backups = []
        recovered.song.title += "（索引恢复副本）"; recovered.modifiedAt = Date()
        recovered = try ProjectFiles.adoptingUnregistered(recovered, root: staging)
        let payload = try FileIntegrity.encoder().encode(recovered)
        guard payload.count <= ProjectArchive.maximumManifestBytes else { throw StudioError("恢复索引超过当前格式安全大小，原件与暂存保留。") }
        try payload.write(to: staging.appendingPathComponent("project.json"), options: .atomic)
        try payload.write(to: staging.appendingPathComponent("project.previous.json"), options: .atomic)
        try files.moveItem(at: staging, to: directory(recovered.id))
        return recovered
    }
}

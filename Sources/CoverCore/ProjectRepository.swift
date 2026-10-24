import Foundation

private struct RestoreTransaction: Codable {
    var projectID: UUID
    var safetyDirectory: String
}

public actor ProjectRepository {
    public nonisolated let root: URL
    private let files = FileManager.default
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.recoverRestore(at: root)
    }
    /// A process termination between the two same-volume renames cannot hide the old project.
    private static func recoverRestore(at root: URL) throws {
        let journal = root.appendingPathComponent(".restore-transaction.json")
        let files = FileManager.default
        guard files.fileExists(atPath: journal.path) else { return }
        let transaction = try JSONDecoder().decode(RestoreTransaction.self, from: Data(contentsOf: journal))
        guard transaction.safetyDirectory.hasPrefix(".safety-"),
              UUID(uuidString: String(transaction.safetyDirectory.dropFirst(8))) != nil else {
            throw StudioError("恢复事务记录无效；现有素材已保留，请勿清理恢复目录。")
        }
        let target = root.appendingPathComponent(transaction.projectID.uuidString)
        let safety = root.appendingPathComponent(transaction.safetyDirectory)
        if !files.fileExists(atPath: target.path) {
            guard files.fileExists(atPath: safety.path) else { throw StudioError("恢复尚未提交且原工程位置不可用，请保留恢复目录。") }
            try files.moveItem(at: safety, to: target)
        }
        try files.removeItem(at: journal)
    }
    public nonisolated func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func loadAll() throws -> [StudioProject] {
        var projects: [StudioProject] = []
        for dir in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where !dir.lastPathComponent.hasPrefix(".") {
            let url = dir.appendingPathComponent("project.json")
            guard files.fileExists(atPath: url.path) else { continue }
            // A corrupt index must be reported, not silently disappear from the library.
            let project = try JSONDecoder().decode(StudioProject.self, from: Data(contentsOf: url))
            guard dir.lastPathComponent == project.id.uuidString else { throw StudioError("工程索引与目录不一致，素材已保留。") }
            if !project.archived { try ProjectRules.validate(project) }
            projects.append(project)
        }
        return projects.sorted { $0.modifiedAt > $1.modifiedAt }
    }
    public func save(_ project: StudioProject) throws {
        if !project.archived { try ProjectRules.validate(project) }
        let dir = directory(project.id)
        try files.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("project.json")
        if files.fileExists(atPath: target.path) {
            let oldData = try Data(contentsOf: target)
            let old = try JSONDecoder().decode(StudioProject.self, from: oldData)
            guard project.revision >= old.revision else { throw StudioError("已有较新的工程修改；请重新打开后再保存。") }
            try oldData.write(to: dir.appendingPathComponent("project.previous.json"), options: .atomic)
        }
        try FileIntegrity.encoder().encode(project).write(to: target, options: .atomic)
    }
    public func makeDirectory(_ id: UUID) throws -> URL {
        let dir = directory(id)
        try files.createDirectory(at: dir.appendingPathComponent("media"), withIntermediateDirectories: true)
        return dir
    }
    public func importAsset(source: URL, projectID: UUID, role: AssetRole, duration: MediaTime = .init(seconds: 0),
                            sampleRate: Double? = nil, channels: Int? = nil) throws -> MediaAsset {
        let dir = try makeDirectory(projectID)
        let bytes = try FileIntegrity.size(source)
        guard bytes > 0, try FileIntegrity.available(dir) > bytes + 32 * 1024 * 1024 else { throw StudioError("文件为空或导入空间不足。") }
        let ext = source.pathExtension.lowercased()
        guard !ext.isEmpty, ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { throw StudioError("文件扩展名无效。") }
        let path = "media/\(UUID().uuidString).\(ext)"
        let destination = try ProjectRules.mediaURL(path, root: dir)
        try files.copyItem(at: source, to: destination)
        do {
            guard try FileIntegrity.size(destination) == bytes else { throw StudioError("导入期间文件大小发生变化，请重新选择原文件。") }
            return try MediaAsset(path: path, role: role, bytes: bytes, sha256: FileIntegrity.sha256(destination),
                                  duration: duration, sampleRate: sampleRate, channels: channels)
        } catch { throw StudioError("导入未提交；已复制的文件保留供恢复。\(error.localizedDescription)") }
    }
    public func registerFile(_ url: URL, projectID: UUID, role: AssetRole, duration: MediaTime,
                             sampleRate: Double? = nil, channels: Int? = nil) throws -> MediaAsset {
        let prefix = directory(projectID).standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(prefix) else { throw StudioError("素材不在工程目录内。") }
        let path = String(url.standardizedFileURL.path.dropFirst(prefix.count))
        _ = try ProjectRules.mediaURL(path, root: directory(projectID))
        return try MediaAsset(path: path, role: role, bytes: FileIntegrity.size(url), sha256: FileIntegrity.sha256(url),
                              duration: duration, sampleRate: sampleRate, channels: channels)
    }
    public func restore(archive: URL, keepBoth: Bool = true) throws -> StudioProject {
        try Self.recoverRestore(at: root)
        let staging = root.appendingPathComponent(".restore-" + UUID().uuidString)
        do {
            let manifest = try ProjectArchive.inspect(archive, extractTo: staging)
            var project = manifest.project
            let target = directory(project.id)
            let conflict = files.fileExists(atPath: target.path)
            if conflict && keepBoth {
                project.originalProjectID = project.originalProjectID ?? project.id
                project.id = UUID(); project.branchID = UUID()
                project.song.title += "（恢复副本）"
            }
            project.archived = false
            project.backups.append(.init(archiveID: manifest.archiveID, revision: manifest.archivedRevision,
                                         level: .restoreVerified, note: "从外部选择的工程包已完整读取校验；不能证明云端永久保留。"))
            try FileIntegrity.encoder().encode(project).write(to: staging.appendingPathComponent("project.json"), options: .atomic)
            if conflict && !keepBoth {
                guard try FileIntegrity.available(root) > 32 * 1024 * 1024 else { throw StudioError("空间不足以安全提交恢复，旧工程未改变。") }
                let transaction = RestoreTransaction(projectID: project.id, safetyDirectory: ".safety-" + UUID().uuidString)
                let journal = root.appendingPathComponent(".restore-transaction.json")
                // Retain every old file by renaming its entire directory to an immutable safety copy.
                // No deletion or second media copy is needed; the new project is already fully staged.
                try FileIntegrity.encoder().encode(transaction).write(to: journal, options: .atomic)
                do {
                    try files.moveItem(at: target, to: root.appendingPathComponent(transaction.safetyDirectory))
                    try files.moveItem(at: staging, to: target)
                } catch {
                    try Self.recoverRestore(at: root)
                    throw error
                }
                // A stale journal is harmless: the next launch sees the committed target and retains safety.
                try? files.removeItem(at: journal)
            } else {
                try files.moveItem(at: staging, to: directory(project.id))
            }
            return project
        } catch {
            // Keep failed staging for diagnosis/retry; never expose it as a complete project.
            throw error
        }
    }
    public func duplicate(_ original: StudioProject) throws -> StudioProject {
        try ProjectRules.validate(original)
        guard !original.archived else { throw StudioError("请先恢复已归档工程，再创建副本。") }
        try requireCurrent(original)
        var copy = original
        copy.originalProjectID = original.id; copy.id = UUID(); copy.branchID = UUID()
        copy.revision = 1; copy.song.title += "（副本）"; copy.backups = []; copy.modifiedAt = Date()
        let source = directory(original.id), destination = directory(copy.id)
        let staging = root.appendingPathComponent(".duplicate-" + UUID().uuidString)
        let payload = try FileIntegrity.encoder().encode(copy)
        let inventory = try ProjectFiles.inventory(root: source, excluding: ["cache", "project.json", "project.previous.json"])
        var total = Int64(payload.count) * 2
        for entry in inventory {
            let (next, overflow) = total.addingReportingOverflow(entry.bytes)
            guard !overflow else { throw StudioError("工程大小无效。") }
            total = next
        }
        guard total <= Int64.max - 32 * 1024 * 1024,
              try FileIntegrity.available(root) > total + 32 * 1024 * 1024 else { throw StudioError("空间不足以复制工程。") }
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        // Count and copy every owned file, including unindexed capture tails and
        // historical exports. Rebuildable cache is intentionally excluded.
        for entry in inventory {
            let input = try ProjectFiles.url(entry.path, root: source), output = try ProjectFiles.url(entry.path, root: staging)
            try files.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.copyItem(at: input, to: output)
            guard try FileIntegrity.size(output) == entry.bytes else { throw StudioError("复制期间文件大小变化，失败暂存已保留。") }
        }
        for asset in original.assets {
            let output = try ProjectRules.mediaURL(asset.path, root: staging)
            guard try FileIntegrity.size(output) == asset.bytes, try FileIntegrity.sha256(output) == asset.sha256 else {
                throw StudioError("副本源素材校验失败，原工程及复制暂存已保留。")
            }
        }
        try payload.write(to: staging.appendingPathComponent("project.json"), options: .atomic)
        try payload.write(to: staging.appendingPathComponent("project.previous.json"), options: .atomic)
        try files.moveItem(at: staging, to: destination)
        return copy
    }
    private func requireCurrent(_ project: StudioProject) throws {
        let current = try JSONDecoder().decode(StudioProject.self, from: Data(contentsOf: directory(project.id).appendingPathComponent("project.json")))
        guard current.id == project.id, current.revision == project.revision else { throw StudioError("工程已有更新，请重新打开后再执行此操作。") }
    }
    public func adoptUnregistered(_ project: StudioProject, paths: Set<String>) throws -> StudioProject {
        guard !project.archived else { throw StudioError("请先恢复工程源素材，再登记原件。") }
        try requireCurrent(project)
        var result = try ProjectFiles.adoptingUnregistered(project, root: directory(project.id), paths: paths)
        result.touch(); try save(result)
        return result
    }
    public func closePendingRecording(_ project: StudioProject, takeID: UUID?) throws -> StudioProject {
        guard !project.archived else { throw StudioError("请先恢复本地工程。") }
        try requireCurrent(project)
        let dir = directory(project.id), journal = try ProjectFiles.url("recording.json", root: dir)
        guard try FileIntegrity.size(journal) <= 16 * 1024 * 1024 else { throw StudioError("录制日志过大，请保留原文件。") }
        let take = try? JSONDecoder().decode(Take.self, from: Data(contentsOf: journal))
        if let takeID {
            guard take?.id == takeID, project.takes.contains(where: { $0.id == takeID }) else { throw StudioError("录制日志已变化，未结束其他录制。") }
        } else if let take, project.takes.contains(where: { $0.id == take.id }) {
            throw StudioError("录制日志可关联到 Take，请刷新后选择对应记录。")
        }
        let retained = try ProjectFiles.url("media/recovery-" + UUID().uuidString + ".json", root: dir)
        try files.createDirectory(at: retained.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.copyItem(at: journal, to: retained)
        var result = try ProjectFiles.adoptingUnregistered(project, root: dir)
        result.touch(); try save(result)
        // Commit the protected originals before clearing the pending marker.
        try files.removeItem(at: journal)
        return result
    }
    /// The UI must present the exact file and receive two confirmations first.
    public func removeUnclaimedMedia(_ project: StudioProject, path: String) throws -> StudioProject {
        try requireCurrent(project)
        let dir = directory(project.id)
        guard !files.fileExists(atPath: dir.appendingPathComponent("recording.json").path) else { throw StudioError("请先恢复或结束待恢复录制，再处理原件。") }
        guard let entry = try ProjectFiles.unclaimedMedia(project: project, root: dir).first(where: { $0.path == path }) else {
            throw StudioError("原件仍被工程引用或路径已变化，已阻止删除。")
        }
        var result = project
        if let id = entry.assetID { result.assets.removeAll { $0.id == id }; result.touch(); try save(result) }
        try files.removeItem(at: ProjectFiles.url(path, root: dir))
        return result
    }
    public func backup(_ project: StudioProject, mode: BackupMode, selected: Set<UUID>, to destination: URL, includeExports: Bool = false,
                       selectedExportPaths: Set<String>? = nil) throws -> ArchiveManifest {
        try ProjectArchive.create(project: project, root: directory(project.id), destination: destination, mode: mode, selected: selected,
                                  includeExports: includeExports, selectedExportPaths: selectedExportPaths)
    }
    public func releaseLocal(_ project: StudioProject, confirmedRevision: Int) throws -> StudioProject {
        guard project.revision == confirmedRevision, project.backups.contains(where: { $0.revision == project.revision && ($0.level == .exportedToProvider || $0.level == .restoreVerified) }) else {
            throw StudioError("当前修改尚未打包，不能释放素材。请重新创建并导出工程包。")
        }
        let dir = directory(project.id)
        guard !files.fileExists(atPath: dir.appendingPathComponent("recording.json").path) else {
            throw StudioError("此工程还有待恢复录制。请先在作品库恢复并结束 Take，再重新备份和释放素材。")
        }
        // Preflight every path before any destructive work or archived-state commit.
        try ProjectRules.validate(project)
        // Source release is separate from the explicitly confirmed per-output
        // deletion flow. Historical exports may not exist in the chosen backup.
        let targets = try project.assets.filter { $0.role != .export }.map { try ProjectRules.mediaURL($0.path, root: dir) }
        var archived = project; archived.archived = true
        // Commit the recoverable index first. Every asset is project-local; no other project shares these paths.
        try save(archived)
        for target in targets {
            if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
        }
        return archived
    }
}

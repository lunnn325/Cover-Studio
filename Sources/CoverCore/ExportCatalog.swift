import Foundation

public struct ExportJob: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var variant: ExportVariant
    public var status: String
    public var path: String?
    public var error: String?
    public init(id: UUID = UUID(), variant: ExportVariant, status: String = "待处理", path: String? = nil, error: String? = nil) {
        self.id = id; self.variant = variant; self.status = status; self.path = path; self.error = error
    }
}

public struct ExportedFile: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public var path: String
    public var variant: ExportVariant?
    public var bytes: Int64
    public var modifiedAt: Date?
    public var completed: Bool
    public var name: String { (path as NSString).lastPathComponent }
    public var label: String { variant?.label ?? "导出文件" }
}

/// The current queue is replaceable; completed history survives a later run.
/// Disk-only files are visible but never promoted to successful exports by a scan.
public enum ExportCatalog {
    private static let metadataLimit: Int64 = 16 * 1024 * 1024
    private static func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
    public static func isOutputPath(_ path: String) -> Bool {
        ProjectRules.safePath(path) && path.hasPrefix("exports/")
            && ["mp4", "mov", "m4a", "wav", "lrc", "txt"].contains((path as NSString).pathExtension.lowercased())
    }
    public static func variant(for path: String) -> ExportVariant? {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        return ExportVariant.allCases.first { name.hasSuffix("-" + $0.rawValue.lowercased() + "." + ext) }
    }
    private static func metadataURL(_ name: String, root: URL) throws -> URL {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let direct = base.appendingPathComponent("exports/" + name)
        guard direct.resolvingSymlinksInPath().path == direct.path else { throw StudioError("导出索引包含符号链接，已停止操作。") }
        return direct
    }
    private static func read(_ name: String, root: URL) throws -> [ExportJob] {
        let url = try metadataURL(name, root: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard try FileIntegrity.size(url) <= metadataLimit else { throw StudioError("导出索引过大，文件已保留，请先备份。") }
        do { return try JSONDecoder().decode([ExportJob].self, from: Data(contentsOf: url)) }
        catch { throw StudioError("导出索引 \(name) 无法读取，原成品已保留。\(error.localizedDescription)") }
    }
    private static func write(_ jobs: [ExportJob], name: String, root: URL) throws {
        let url = try metadataURL(name, root: root), data = try FileIntegrity.encoder().encode(jobs)
        guard Int64(data.count) <= metadataLimit else { throw StudioError("导出索引超出容量限制，原记录已保留。") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    public static func queue(root: URL) throws -> [ExportJob] { try read("queue.json", root: root) }
    public static func samePath(_ left: String, _ right: String) -> Bool { key(left) == key(right) }
    public static func rememberCompleted(_ jobs: [ExportJob], root: URL) throws {
        let previous = try read("history.json", root: root)
        var byPath: [String: ExportJob] = [:]
        for job in previous + jobs where job.status == "完成" {
            guard let path = job.path, isOutputPath(path) else { throw StudioError("成品记录的路径无效，原索引未覆盖。") }
            _ = try ProjectRules.mediaURL(path, root: root)
            byPath[key(path)] = job
        }
        try write(byPath.values.sorted { ($0.path ?? "") < ($1.path ?? "") }, name: "history.json", root: root)
    }
    public static func saveQueue(_ jobs: [ExportJob], root: URL) throws {
        // Make old and new completions durable before replacing the current
        // queue. A queue-write failure still leaves every completed file known.
        try rememberCompleted(try queue(root: root) + jobs, root: root)
        try write(jobs, name: "queue.json", root: root)
    }
    public static func outputs(root: URL, assets: [MediaAsset] = []) throws -> [ExportedFile] {
        let jobs = try read("history.json", root: root) + queue(root: root)
        var completed = Set<String>()
        for job in jobs where job.status == "完成" {
            guard let path = job.path, isOutputPath(path) else { throw StudioError("成品记录包含不安全路径，文件已保留。") }
            completed.insert(key(path))
        }
        completed.formUnion(assets.filter { $0.role == .export && isOutputPath($0.path) }.map { key($0.path) })
        let directory = try metadataURL("queue.json", root: root).deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let properties: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var enumerationError: Error?
        guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(properties),
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw StudioError("导出目录无法读取，文件未修改。")
        }
        var result: [ExportedFile] = []
        for case let url as URL in iterator {
            let values = try url.resourceValues(forKeys: properties)
            if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
            guard values.isRegularFile == true else { continue }
            let path = "exports/" + String(url.path.dropFirst(directory.path.count + 1))
            guard isOutputPath(path) else { continue }
            _ = try ProjectRules.mediaURL(path, root: root)
            result.append(ExportedFile(path: path, variant: variant(for: path), bytes: Int64(values.fileSize ?? 0),
                                       modifiedAt: values.contentModificationDate, completed: completed.contains(key(path)) && (values.fileSize ?? 0) > 0))
        }
        if let enumerationError { throw enumerationError }
        return result.sorted {
            let left = $0.modifiedAt ?? .distantPast, right = $1.modifiedAt ?? .distantPast
            return left == right ? $0.path < $1.path : left > right
        }
    }
    /// Call only after the UI's second explicit confirmation and dependency check.
    public static func removeOutput(path: String, root: URL) throws {
        guard isOutputPath(path) else { throw StudioError("只能移除明确选中的导出媒体或歌词文件。") }
        let target = try ProjectRules.mediaURL(path, root: root)
        var jobs = try queue(root: root)
        let history = try read("history.json", root: root).filter { $0.path.map(key) != key(path) }
        for index in jobs.indices where jobs[index].path.map(key) == key(path) {
            jobs[index].status = "已删除"; jobs[index].path = nil
        }
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try write(jobs, name: "queue.json", root: root)
        try write(history, name: "history.json", root: root)
    }
}

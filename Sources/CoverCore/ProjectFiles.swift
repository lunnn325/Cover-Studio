import Foundation

public struct ProjectFile: Equatable, Sendable {
    public let path: String
    public let bytes: Int64
}
public struct UnclaimedMediaFile: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let bytes: Int64
    public let assetID: UUID?
    public var name: String { (path as NSString).lastPathComponent }
}

public enum ProjectFiles {
    private static func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
    public static func url(_ path: String, root: URL) throws -> URL {
        guard ProjectRules.safePath(path) else { throw StudioError("工程文件路径无效。") }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let direct = path.split(separator: "/").reduce(base) { $0.appendingPathComponent(String($1)) }.standardizedFileURL
        guard direct.path == direct.resolvingSymlinksInPath().path, direct.path.hasPrefix(base.path + "/") else {
            throw StudioError("工程文件包含符号链接或超出目录，已停止操作。")
        }
        return direct
    }
    public static func inventory(root: URL, excluding: Set<String> = []) throws -> [ProjectFile] {
        var result: [ProjectFile] = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        func visit(_ folder: URL, prefix: String) throws {
            for child in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) {
                let path = prefix.isEmpty ? child.lastPathComponent : prefix + "/" + child.lastPathComponent
                if excluding.contains(path) { continue }
                guard ProjectRules.safePath(path) else { throw StudioError("工程含不安全的文件名，原文件已保留。") }
                let values = try child.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true else { throw StudioError("工程含符号链接，不能安全复制或登记。") }
                if values.isDirectory == true { try visit(child, prefix: path) }
                else {
                    guard values.isRegularFile == true else { throw StudioError("工程含非普通文件，已停止操作。") }
                    result.append(ProjectFile(path: path, bytes: try FileIntegrity.size(child)))
                }
            }
        }
        try visit(root, prefix: "")
        return result.sorted { $0.path < $1.path }
    }
    public static func requiredAssetIDs(_ project: StudioProject) -> Set<UUID> {
        var required = project.arrangements.reduce(into: Set<UUID>()) { $0.formUnion($1.assetIDs) }
        project.takes.forEach { required.formUnion($0.assetIDs) }
        required.formUnion([project.edit.visualAssetID, project.song.coverAssetID].compactMap { $0 })
        return required
    }
    public static func unclaimedMedia(project: StudioProject, root: URL) throws -> [UnclaimedMediaFile] {
        try ProjectRules.validate(project)
        let media = try url("media", root: root)
        guard FileManager.default.fileExists(atPath: media.path) else { return [] }
        let required = requiredAssetIDs(project)
        let assets = Dictionary(uniqueKeysWithValues: project.assets.map { (key($0.path), $0) })
        return try inventory(root: media).compactMap { entry in
            let path = "media/" + entry.path, asset = assets[key(path)]
            guard asset?.role != .export, asset.map({ !required.contains($0.id) }) ?? true else { return nil }
            return UnclaimedMediaFile(path: path, bytes: entry.bytes, assetID: asset?.id)
        }
    }
    /// Preserve bytes with unknown duration. This does not create a Take,
    /// infer synchronization, repair a container, or claim that it is playable.
    public static func adoptingUnregistered(_ project: StudioProject, root: URL, paths: Set<String>? = nil) throws -> StudioProject {
        var result = project
        let files = try unclaimedMedia(project: project, root: root).filter { $0.assetID == nil }
        let selected = paths.map { Set($0.map(key)) }
        if let selected {
            guard selected.isSubset(of: Set(files.map { key($0.path) })) else { throw StudioError("所选未登记原件已变化，请刷新后重试。") }
        }
        for file in files where selected == nil || selected!.contains(key(file.path)) {
            let source = try url(file.path, root: root)
            let size = try FileIntegrity.size(source)
            guard size == file.bytes else { throw StudioError("原件仍在变化，请结束当前操作后再登记。") }
            result.assets.append(MediaAsset(path: file.path, role: .source, bytes: size, sha256: try FileIntegrity.sha256(source)))
        }
        try ProjectRules.validate(result)
        return result
    }
    public static func isRetainedDirectory(_ name: String) -> Bool {
        for prefix in [".safety-", ".restore-", ".replaced-", ".duplicate-"] where name.hasPrefix(prefix) {
            return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
        }
        return false
    }
}

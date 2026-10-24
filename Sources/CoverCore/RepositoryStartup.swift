import Foundation

public struct PendingRestoreLog: Equatable, Sendable {
    public let bytes: Int64
    public let sha256: String
}
public struct RetainedStartupLog: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let bytes: Int64
}

public enum RepositoryStartup {
    private static let pendingName = ".restore-transaction.json"
    private static let retainedPrefix = ".startup-transaction-"
    private static func regularLog(_ name: String, root: URL) throws -> URL {
        let url = try ProjectFiles.url(name, root: root)
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              try FileIntegrity.size(url) <= Int64(ProjectArchive.maximumManifestBytes) else {
            throw StudioError("恢复事务日志不是普通文件或超出安全大小，原件未修改。")
        }
        return url
    }
    public static func pending(root: URL) throws -> PendingRestoreLog? {
        let url = try ProjectFiles.url(pendingName, root: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        _ = try regularLog(pendingName, root: root)
        return PendingRestoreLog(bytes: try FileIntegrity.size(url), sha256: try FileIntegrity.sha256(url))
    }
    /// Explicit user action only: preserve the exact marker, without touching project directories.
    public static func preservePending(root: URL, expected: PendingRestoreLog) throws -> URL {
        guard try pending(root: root) == expected else { throw StudioError("恢复事务日志已变化，请重新检查后确认。") }
        let input = try regularLog(pendingName, root: root)
        let output = try ProjectFiles.url(retainedPrefix + UUID().uuidString + ".json", root: root)
        try FileManager.default.moveItem(at: input, to: output)
        guard try FileIntegrity.sha256(output) == expected.sha256 else {
            throw StudioError("已保留的日志校验失败，请保留整个目录，未恢复任何工程。")
        }
        return output
    }
    public static func isRetainedLog(_ name: String) -> Bool {
        guard name.hasPrefix(retainedPrefix), name.hasSuffix(".json") else { return false }
        return UUID(uuidString: String(name.dropFirst(retainedPrefix.count).dropLast(5))) != nil
    }
    public static func retainedLogs(root: URL) throws -> [RetainedStartupLog] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { isRetainedLog($0.lastPathComponent) }
            .map { url in
                let safe = try regularLog(url.lastPathComponent, root: root)
                return RetainedStartupLog(name: url.lastPathComponent, bytes: try FileIntegrity.size(safe))
            }.sorted { $0.name < $1.name }
    }
    public static func retainedLogURL(_ name: String, root: URL) throws -> URL {
        guard isRetainedLog(name) else { throw StudioError("不是受控启动恢复日志。") }
        return try regularLog(name, root: root)
    }
}

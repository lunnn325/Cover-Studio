import Foundation
import CryptoKit

public enum FileIntegrity {
    public static func sha256(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256()
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    public static func readExactly(_ input: FileHandle, count: Int) throws -> Data {
        guard count >= 0 else { throw StudioError("工程包长度无效。") }
        var result = Data()
        while result.count < count {
            guard let block = try input.read(upToCount: count - result.count), !block.isEmpty else { throw StudioError("工程包不完整。") }
            result.append(block)
        }
        return result
    }
    public static func size(_ url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular else { throw StudioError("素材不是普通文件。") }
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }
    public static func available(_ url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        return (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder
    }
    public static func copyStream(from input: FileHandle, to output: FileHandle, count: Int64) throws -> String {
        guard count >= 0 else { throw StudioError("工程包长度无效。") }
        var remaining = count, hash = SHA256()
        while remaining > 0 {
            guard let block = try input.read(upToCount: Int(min(remaining, 1024 * 1024))), !block.isEmpty else {
                throw StudioError("工程包不完整。")
            }
            try output.write(contentsOf: block); hash.update(data: block); remaining -= Int64(block.count)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct ArchiveManifest: Codable, Sendable {
    public var schemaVersion = 1
    public var minReaderVersion = 1
    public var appVersion = "1.0"
    public var archiveID = UUID()
    public var originalProjectID: UUID
    public var archivedRevision: Int
    public var sourceDeviceID: String
    public var createdAt = Date()
    public var hashAlgorithm = "SHA-256"
    public var featureFlags = ["rational-time", "immutable-assets", "segment-overlap"]
    public var mode: BackupMode
    public var project: StudioProject
    public init(project: StudioProject, mode: BackupMode) {
        self.project = project; self.mode = mode; originalProjectID = project.id
        archivedRevision = project.revision; sourceDeviceID = project.sourceDeviceID
    }
}

/// COVERP01 + UInt64 big-endian manifest length + SHA256(manifest) + JSON + concatenated assets.
/// No compressed input, path extraction API, or unbounded in-memory media allocations.
public enum ProjectArchive {
    public static let magic = Data("COVERP01".utf8)
    public static let maximumManifestBytes = 16 * 1024 * 1024
    public static let maximumAssetCount = 20_000
    public static let maximumTotalBytes: Int64 = 512 * 1024 * 1024 * 1024

    @discardableResult
    public static func create(project: StudioProject, root: URL, destination: URL,
                              mode: BackupMode, selected: Set<UUID> = [], includeExports: Bool = false) throws -> ArchiveManifest {
        let payload = try ProjectRules.backupProject(project, mode: mode, selected: selected, includeExports: includeExports)
        let manifest = ArchiveManifest(project: payload, mode: mode)
        let json = try FileIntegrity.encoder().encode(manifest)
        guard json.count <= maximumManifestBytes, payload.assets.count <= maximumAssetCount else {
            throw StudioError("工程清单过大。请减少未引用的 Take。")
        }
        let total = try checkedTotal(payload.assets)
        guard try FileIntegrity.available(destination.deletingLastPathComponent()) > total + Int64(json.count) + 32 * 1024 * 1024 else {
            throw StudioError("创建工程包所需空间不足。请更换目标或先处理可重建缓存。")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw StudioError("目标文件已存在，不会覆盖。") }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".partial")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let output = try FileHandle(forWritingTo: temporary)
        do {
            try output.write(contentsOf: magic)
            var length = UInt64(json.count).bigEndian
            try withUnsafeBytes(of: &length) { try output.write(contentsOf: Data($0)) }
            try output.write(contentsOf: FileIntegrity.digest(json)); try output.write(contentsOf: json)
            for asset in payload.assets {
                let url = try ProjectRules.mediaURL(asset.path, root: root)
                guard try FileIntegrity.size(url) == asset.bytes else { throw StudioError("素材大小已改变。原件已保留，请检查工程。") }
                let input = try FileHandle(forReadingFrom: url)
                let digest: String
                do { digest = try FileIntegrity.copyStream(from: input, to: output, count: asset.bytes); try input.close() }
                catch { try? input.close(); throw error }
                guard digest == asset.sha256 else { throw StudioError("素材哈希不匹配，工程包未提交。") }
            }
            try output.synchronize(); try output.close()
            // Re-read the exact generated bytes before publishing the archive.
            _ = try inspect(temporary)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return manifest
        } catch {
            try? output.close()
            // Only this operation's generated partial file, never user source media.
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    public static func readManifest(_ input: FileHandle) throws -> ArchiveManifest {
        guard try FileIntegrity.readExactly(input, count: 8) == magic else { throw StudioError("不是可识别的 My Cover Studio 工程包。") }
        let lengthData = try FileIntegrity.readExactly(input, count: 8)
        let length = lengthData.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard length > 0 && length <= UInt64(maximumManifestBytes) else { throw StudioError("工程清单大小超限。") }
        let hash = try FileIntegrity.readExactly(input, count: 32)
        let json = try FileIntegrity.readExactly(input, count: Int(length))
        guard FileIntegrity.digest(json) == hash else { throw StudioError("工程清单校验失败。") }
        let manifest = try JSONDecoder().decode(ArchiveManifest.self, from: json)
        guard manifest.schemaVersion == 1, manifest.minReaderVersion >= 1, manifest.minReaderVersion <= 1,
              manifest.hashAlgorithm == "SHA-256",
              Set(manifest.featureFlags).isSubset(of: ["rational-time", "immutable-assets", "segment-overlap"]),
              manifest.originalProjectID == manifest.project.id,
              manifest.archivedRevision == manifest.project.revision,
              manifest.sourceDeviceID == manifest.project.sourceDeviceID else {
            throw StudioError("工程版本或功能不兼容，请更新 App。")
        }
        try ProjectRules.validate(manifest.project)
        _ = try checkedTotal(manifest.project.assets)
        return manifest
    }

    private static func checkedTotal(_ assets: [MediaAsset]) throws -> Int64 {
        guard assets.count <= maximumAssetCount else { throw StudioError("工程素材数量超限。") }
        var total: Int64 = 0
        for asset in assets {
            guard asset.bytes >= 0, asset.bytes <= maximumTotalBytes - total else { throw StudioError("工程大小超限。") }
            total += asset.bytes
        }
        return total
    }

    @discardableResult
    public static func inspect(_ archive: URL, extractTo staging: URL? = nil) throws -> ArchiveManifest {
        let input = try FileHandle(forReadingFrom: archive); defer { try? input.close() }
        let manifest = try readManifest(input)
        let total = try checkedTotal(manifest.project.assets)
        let offset = try input.offset()
        guard try FileIntegrity.size(archive) == Int64(offset) + total else { throw StudioError("工程包长度与清单不符。") }
        if let staging {
            guard try FileIntegrity.available(staging.deletingLastPathComponent()) > total + 32 * 1024 * 1024 else {
                throw StudioError("恢复空间不足，现有工程不会被覆盖。")
            }
            guard !FileManager.default.fileExists(atPath: staging.path) else { throw StudioError("恢复暂存位置冲突。") }
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        }
        for asset in manifest.project.assets {
            var hash = SHA256(), remaining = asset.bytes
            var output: FileHandle?
            if let staging {
                let url = try ProjectRules.mediaURL(asset.path, root: staging)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard !FileManager.default.fileExists(atPath: url.path),
                      FileManager.default.createFile(atPath: url.path, contents: nil) else { throw StudioError("恢复素材路径冲突。") }
                output = try FileHandle(forWritingTo: url)
            }
            do {
                while remaining > 0 {
                    guard let data = try input.read(upToCount: Int(min(remaining, 1024 * 1024))), !data.isEmpty else { throw StudioError("工程包缺少素材数据。") }
                    hash.update(data: data); try output?.write(contentsOf: data); remaining -= Int64(data.count)
                }
                try output?.synchronize(); try output?.close()
            } catch { try? output?.close(); throw error }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == asset.sha256 else {
                throw StudioError("素材 SHA-256 校验失败；不会导入或覆盖现有工程。")
            }
        }
        return manifest
    }
}

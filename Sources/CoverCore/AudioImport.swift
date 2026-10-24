import Foundation
import AVFAudio
import CVorbis

/// A temporary decoding result. Original bytes always remain a separate asset.
public struct PreparedAudio: Sendable {
    public let sourceURL: URL
    public let sourceSHA256: String
    public let playbackURL: URL
    public let frames: Int64
    public let sampleRate: Double
    public let channels: Int
    private let ownedTemporaryDirectory: URL?
    public var duration: MediaTime { .init(seconds: Double(frames) / sampleRate) }
    public var converted: Bool { ownedTemporaryDirectory != nil }
    fileprivate init(sourceURL: URL, sourceSHA256: String, playbackURL: URL, frames: Int64,
                     sampleRate: Double, channels: Int, ownedTemporaryDirectory: URL? = nil) {
        self.sourceURL = sourceURL; self.sourceSHA256 = sourceSHA256; self.playbackURL = playbackURL
        self.frames = frames; self.sampleRate = sampleRate; self.channels = channels
        self.ownedTemporaryDirectory = ownedTemporaryDirectory
    }
    /// Only removes the UUID directory created by this import, never the source.
    public func removeTemporaryFiles() {
        if let ownedTemporaryDirectory { try? FileManager.default.removeItem(at: ownedTemporaryDirectory) }
    }
}

public enum AudioImport {
    public static let extensions: Set<String> = ["mp3", "m4a", "wav", "wave", "aac", "flac", "aif", "aiff", "aifc", "caf", "ogg", "oga"]
    public static let formatDescription = "MP3、M4A、WAV、AAC、FLAC、AIFF、CAF、OGG/Vorbis"

    /// Synchronous, bounded-buffer work; callers should run on a worker task.
    public static func prepare(_ source: URL, temporaryRoot: URL = FileManager.default.temporaryDirectory) throws -> PreparedAudio {
        guard extensions.contains(source.pathExtension.lowercased()) else {
            throw StudioError("请选择支持的音频：\(formatDescription)。")
        }
        guard try FileIntegrity.size(source) > 0 else { throw StudioError("音频文件为空。") }
        let fingerprint = try FileIntegrity.sha256(source)
        let input = try FileHandle(forReadingFrom: source)
        let signature: Data
        do { signature = try input.read(upToCount: 4) ?? Data(); try input.close() }
        catch { try? input.close(); throw error }
        if signature == Data("OggS".utf8) { return try decodeVorbis(source, fingerprint: fingerprint, temporaryRoot: temporaryRoot) }
        if ["ogg", "oga"].contains(source.pathExtension.lowercased()) { throw StudioError("这不是完整的 OGG 音频文件，原文件未修改。") }
        do {
            let file = try AVAudioFile(forReading: source)
            let rate = file.processingFormat.sampleRate, channels = Int(file.processingFormat.channelCount)
            guard rate.isFinite, rate > 0, channels > 0, file.length > 0 else {
                throw StudioError("音频采样信息无效或时长为空。")
            }
            return PreparedAudio(sourceURL: source, sourceSHA256: fingerprint, playbackURL: source,
                                 frames: file.length, sampleRate: rate, channels: channels)
        } catch let error as StudioError { throw error }
        catch { throw StudioError("系统无法解码此音频，可能是编码不受支持、文件损坏或受保护。原文件未修改。") }
    }

    private static func decodeVorbis(_ source: URL, fingerprint: String, temporaryRoot: URL) throws -> PreparedAudio {
        var error: Int32 = 0
        guard let decoder = source.path.withCString({ mc_vorbis_open($0, &error) }) else {
            switch error {
            case 2: throw StudioError("此 OGG 使用的不是 Vorbis 编码（可能是 Opus）。当前支持 OGG/Vorbis，请先转换为 WAV、FLAC 或 M4A。原文件未修改。")
            case 3: throw StudioError("当前不支持串接或多流 OGG，请先转换为单一音频文件。原文件未修改。")
            case 4: throw StudioError("OGG 需为 8–192 kHz 单声道或立体声，且长度在解码器支持范围内。原文件未修改。")
            default: throw StudioError("OGG/Vorbis 无法完整解码（错误 \(error)），可能已损坏、截断或使用不支持的旧编码。原文件未修改。")
            }
        }
        defer { mc_vorbis_close(decoder) }
        let rate = Double(mc_vorbis_rate(decoder)), channels = Int(mc_vorbis_channels(decoder))
        let expected = Int64(mc_vorbis_frames(decoder))
        let required = expected * Int64(channels) * 4
        // Two copies at peak (temporary CAF + committed asset), source copy and reserve.
        guard try FileIntegrity.available(temporaryRoot) > required * 2 + FileIntegrity.size(source) + 32 * 1024 * 1024 else {
            throw StudioError("空间不足以在本机解码 OGG 并保存原件，请先释放可重建缓存或备份其他工程。")
        }
        let directory = temporaryRoot.appendingPathComponent("AudioImport-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            try Task.checkCancellation()
            let output = directory.appendingPathComponent("decoded.caf")
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                            channels: AVAudioChannelCount(channels), interleaved: true),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
                  let samples = buffer.floatChannelData?[0] else { throw StudioError("无法创建 OGG 解码缓冲。") }
            let writer = try AVAudioFile(forWriting: output, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
            var written: Int64 = 0
            while true {
                try Task.checkCancellation()
                let count = mc_vorbis_read(decoder, samples, Int32(buffer.frameCapacity) * Int32(channels))
                guard mc_vorbis_error(decoder) == 0 else { throw StudioError("OGG 解码遇到损坏片段，未导入部分音频。原件未修改。") }
                if count == 0 { break }
                guard count > 0, written + Int64(count) <= expected else { throw StudioError("OGG 实际音频长度与容器记录不符，未导入。") }
                buffer.frameLength = AVAudioFrameCount(count)
                try writer.write(from: buffer); written += Int64(count)
            }
            guard written == expected else { throw StudioError("OGG 音频不完整，未把部分解码结果当作成功导入。原件未修改。") }
            return PreparedAudio(sourceURL: source, sourceSHA256: fingerprint, playbackURL: output,
                                 frames: written, sampleRate: rate, channels: channels, ownedTemporaryDirectory: directory)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
}

public struct ImportedAudioAssets: Sendable {
    public var arrangement: Arrangement
    public var assets: [MediaAsset]
}

extension ProjectRepository {
    public func importPreparedAudio(_ prepared: PreparedAudio, projectID: UUID, isBacking: Bool) throws -> ImportedAudioAssets {
        let source = try importAsset(source: prepared.sourceURL, projectID: projectID,
                                    role: isBacking && !prepared.converted ? .backing : .source,
                                    duration: prepared.duration, sampleRate: prepared.sampleRate, channels: prepared.channels)
        guard source.sha256 == prepared.sourceSHA256 else { throw StudioError("导入期间原文件已变化，文件已保留但未提交工程，请重新选择。") }
        var result = ImportedAudioAssets(arrangement: Arrangement(sourceAssetID: source.id, isBacking: false), assets: [source])
        if isBacking {
            if prepared.converted {
                let decoded = try importAsset(source: prepared.playbackURL, projectID: projectID, role: .backing,
                                              duration: prepared.duration, sampleRate: prepared.sampleRate, channels: prepared.channels)
                result.assets.append(decoded); result.arrangement.backingAssetID = decoded.id
            } else { result.arrangement.backingAssetID = source.id }
        }
        return result
    }
}

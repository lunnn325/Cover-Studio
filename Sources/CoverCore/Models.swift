import Foundation

public struct StudioError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct MediaTime: Codable, Equatable, Sendable {
    public var value: Int64
    public var timescale: Int32
    public init(value: Int64, timescale: Int32) {
        self.value = value; self.timescale = timescale
    }
    public init(seconds: Double) {
        let scaled = (seconds * 600_000).rounded()
        guard scaled.isFinite, scaled > Double(Int64.min), scaled < Double(Int64.max) else {
            self.value = 0; self.timescale = 0; return
        }
        self.value = Int64(scaled); self.timescale = 600_000
    }
    public var seconds: Double { Double(value) / Double(max(1, timescale)) }
}

public enum AssetRole: String, Codable, Sendable {
    case source, backing, vocal, video, image, originalVocal, export
}

public struct MediaAsset: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var path: String
    public var role: AssetRole
    public var bytes: Int64
    public var sha256: String
    public var duration: MediaTime
    public var sampleRate: Double?
    public var channels: Int?
    public init(path: String, role: AssetRole, bytes: Int64, sha256: String,
                duration: MediaTime = .init(seconds: 0), sampleRate: Double? = nil, channels: Int? = nil) {
        self.path = path; self.role = role; self.bytes = bytes; self.sha256 = sha256
        self.duration = duration; self.sampleRate = sampleRate; self.channels = channels
    }
}

public struct Song: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var title: String
    public var artist: String
    public var group: String = ""
    public var coverAssetID: UUID?
    public init(title: String, artist: String = "") { self.title = title; self.artist = artist }
}

public struct LyricLine: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var text: String
    public var time: Double?
    public init(text: String, time: Double? = nil) { self.text = text; self.time = time }
}

public struct Lyrics: Codable, Equatable, Sendable {
    public var lines: [LyricLine] = []
    public var offset: Double = 0
    public init() {}
    public var isTimed: Bool {
        !lines.isEmpty && lines.allSatisfy { $0.time != nil && $0.time!.isFinite && $0.time! >= 0 }
        && zip(lines, lines.dropFirst()).allSatisfy { $0.0.time! <= $0.1.time! }
    }
    public func activeIndex(at time: Double) -> Int? {
        lines.lastIndex { ($0.time.map { $0 + offset <= time }) == true }
    }
    public func lrc() -> String {
        lines.map { line in
            guard let time = line.time, time.isFinite, offset.isFinite else { return line.text }
            let adjusted = max(0, time + offset)
            guard adjusted.isFinite, adjusted < Double(Int64.max / 100) else { return line.text }
            // Round before splitting minutes so 59.999 becomes [01:00.00], never [00:60.00].
            let hundredths = Int64((adjusted * 100).rounded())
            return String(format: "[%02lld:%02lld.%02lld]", hundredths / 6000, (hundredths / 100) % 60, hundredths % 100) + line.text
        }.joined(separator: "\n")
    }
}

public struct Arrangement: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var name = "伴奏 1"
    public var sourceAssetID: UUID
    public var backingAssetID: UUID?
    public var originalVocalAssetID: UUID?
    public var semitones: Int = 0
    public var lyrics = Lyrics()
    public init(sourceAssetID: UUID, isBacking: Bool) {
        self.sourceAssetID = sourceAssetID
        self.backingAssetID = isBacking ? sourceAssetID : nil
    }
    public var assetIDs: Set<UUID> {
        Set([sourceAssetID, backingAssetID, originalVocalAssetID].compactMap { $0 })
    }
}

public enum TakeKind: String, Codable, Sendable { case audio, video }
public struct RecordingSegment: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    /// Take-local capture order survives device reboot; absent in early schema-1 packages.
    public var sequence: Int?
    public var vocalAssetID: UUID
    public var videoAssetID: UUID?
    public var songStart: MediaTime
    public var hostStart: MediaTime
    public var duration: MediaTime
    public var audioFirstPTS: MediaTime?
    public var videoFirstPTS: MediaTime?
    public var playbackHostTime: UInt64
    public var inputLatency: Double
    public var outputLatency: Double
    public var route: String
    public init(vocalAssetID: UUID, videoAssetID: UUID?, songStart: MediaTime,
                hostStart: MediaTime, duration: MediaTime, audioFirstPTS: MediaTime?,
                videoFirstPTS: MediaTime?, playbackHostTime: UInt64,
                inputLatency: Double, outputLatency: Double, route: String) {
        self.vocalAssetID = vocalAssetID; self.videoAssetID = videoAssetID
        self.songStart = songStart; self.hostStart = hostStart; self.duration = duration
        self.audioFirstPTS = audioFirstPTS; self.videoFirstPTS = videoFirstPTS
        self.playbackHostTime = playbackHostTime; self.inputLatency = inputLatency
        self.outputLatency = outputLatency; self.route = route
    }
    public var assetIDs: Set<UUID> { Set([vocalAssetID, videoAssetID].compactMap { $0 }) }
}

public struct Take: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var createdAt = Date()
    public var kind: TakeKind
    public var arrangementID: UUID
    public var semitones: Int
    public var segments: [RecordingSegment] = []
    public var favorite = false
    public var isPractice = false
    public var promotedTakeID: UUID?
    public init(name: String, kind: TakeKind, arrangementID: UUID, semitones: Int, isPractice: Bool = false) {
        self.name = name; self.kind = kind; self.arrangementID = arrangementID
        self.semitones = semitones; self.isPractice = isPractice
    }
    public var assetIDs: Set<UUID> { segments.reduce(into: Set<UUID>()) { $0.formUnion($1.assetIDs) } }
    public var end: Double { segments.map { $0.songStart.seconds + $0.duration.seconds }.max() ?? 0 }
}

public struct SubtitleStyle: Codable, Equatable, Sendable {
    public var fontName = "PingFangSC-Semibold"
    public var size: Double = 42
    public var verticalPosition: Double = 0.14
    public var whiteText = true
    public var shadow = true
    /// Black outline width in output pixels; zero preserves early schema-1 rendering.
    public var outlineWidth: Double = 0
    public init() {}
    private enum CodingKeys: String, CodingKey { case fontName, size, verticalPosition, whiteText, shadow, outlineWidth }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fontName = try values.decode(String.self, forKey: .fontName)
        size = try values.decode(Double.self, forKey: .size)
        verticalPosition = try values.decode(Double.self, forKey: .verticalPosition)
        whiteText = try values.decode(Bool.self, forKey: .whiteText)
        shadow = try values.decode(Bool.self, forKey: .shadow)
        outlineWidth = try values.decodeIfPresent(Double.self, forKey: .outlineWidth) ?? 0
    }
}

public struct EditGraph: Codable, Equatable, Sendable {
    public var selectedTakeID: UUID?
    public var vocalGain: Double = 1
    public var backingGain: Double = 0.7
    public var bassDB: Double = 0
    public var presenceDB: Double = 0
    public var reverb: Double = 8
    public var highPassHz: Double = 70
    public var syncOffset: Double = 0
    public var trimStart: Double = 0
    public var trimEnd: Double?
    public var aspect: Double = 9.0 / 16.0
    public var mirrorExport = false
    public var visualAssetID: UUID?
    public var visualSongStart: Double = 0
    public var visualOffset: Double = 0
    public var subtitleStyle = SubtitleStyle()
    public var subtitleStart: Double = 0
    public var subtitleEnd: Double?
    public var referencedTakeIDs: Set<UUID> = []
    /// Explicit song-time replacement cuts; later segments replace overlapping earlier ones.
    public var segmentStartOverrides: [UUID: Double] = [:]
    public init() {}
}

public enum ExportVariant: String, Codable, CaseIterable, Sendable {
    case subtitledVideo, cleanVideo, mixAudio, dryVocal, backing, lyrics
    public var label: String {
        switch self {
        case .subtitledVideo: return "带字幕视频"
        case .cleanVideo: return "无字幕视频"
        case .mixAudio: return "混音音频"
        case .dryVocal: return "独立干声"
        case .backing: return "变调伴奏"
        case .lyrics: return "歌词 LRC / TXT"
        }
    }
}
public enum AudioExportFormat: String, Codable, CaseIterable, Sendable { case m4a, wav }
public struct ExportPreset: Codable, Equatable, Sendable {
    public var variants: Set<ExportVariant> = [.subtitledVideo, .cleanVideo]
    public var audioFormat: AudioExportFormat = .m4a
    public init() {}
    public func validate(lyrics: Lyrics, hasVideo: Bool) throws {
        guard !variants.isEmpty else { throw StudioError("请至少选择一个输出文件。") }
        if variants.contains(.subtitledVideo) && !lyrics.isTimed {
            throw StudioError("歌词尚未逐句标记。请先标记时间点，或取消带字幕视频。")
        }
        if !hasVideo && (!variants.isDisjoint(with: [.subtitledVideo, .cleanVideo])) {
            throw StudioError("纯音频 Take 需要先选择照片或补拍画面，才能导出视频。")
        }
    }
}

public enum BackupLevel: String, Codable, Sendable {
    case activeLocal, archivePrepared, exportedToProvider, restoreVerified, archivedIndexOnly
    public var label: String {
        switch self {
        case .activeLocal: return "仅本地工程"
        case .archivePrepared: return "本地工程包已校验"
        case .exportedToProvider: return "已交给文件提供者，云上传未验证"
        case .restoreVerified: return "外部工程包恢复已验证"
        case .archivedIndexOnly: return "已归档，本地素材已移除"
        }
    }
}
public struct BackupRecord: Codable, Equatable, Sendable {
    public var archiveID: UUID
    public var date: Date
    public var revision: Int
    public var level: BackupLevel
    public var note: String
    public init(archiveID: UUID, revision: Int, level: BackupLevel, note: String) {
        self.archiveID = archiveID; self.date = Date(); self.revision = revision
        self.level = level; self.note = note
    }
}
public struct StudioProject: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var originalProjectID: UUID?
    public var schemaVersion = 1
    public var revision = 1
    public var branchID = UUID()
    public var sourceDeviceID: String
    public var modifiedAt = Date()
    public var song: Song
    public var arrangementID: UUID
    public var arrangements: [Arrangement]
    public var assets: [MediaAsset]
    public var takes: [Take] = []
    public var edit = EditGraph()
    public var exportPreset = ExportPreset()
    public var backups: [BackupRecord] = []
    public var archived = false
    public var loopStart: Double = 0
    public var loopEnd: Double = 0
    public var mirrorPreview = true
    public var frontCamera = true
    public var showLyrics = true
    public var landscapeRecording = false
    public var recordVideo = true
    public init(song: Song, arrangement: Arrangement, assets: [MediaAsset], sourceDeviceID: String) {
        self.song = song; self.arrangementID = arrangement.id; self.arrangements = [arrangement]
        self.assets = assets; self.sourceDeviceID = sourceDeviceID
    }
    public var arrangement: Arrangement? { arrangements.first { $0.id == arrangementID } }
    public var selectedTake: Take? { takes.first { $0.id == edit.selectedTakeID } }
    public func asset(_ id: UUID) -> MediaAsset? { assets.first { $0.id == id } }
    public func arrangement(for take: Take) -> Arrangement? { arrangements.first { $0.id == take.arrangementID } }
    public mutating func touch() { revision += 1; modifiedAt = Date() }
}

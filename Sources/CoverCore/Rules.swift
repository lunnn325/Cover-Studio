import Foundation

public enum LRCParser {
    public struct Result {
        public var lyrics: Lyrics
        public var warnings: [String]
    }
    public static func parse(_ text: String) -> Result {
        var lyrics = Lyrics(), warnings: [String] = []
        let expression = try! NSRegularExpression(pattern: #"\[(\d+):(\d{2}(?:\.\d+)?)\]"#)
        for source in text.components(separatedBy: .newlines) {
            let line = source.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("[offset:"), let close = line.firstIndex(of: "]"),
               let ms = Double(line[line.index(line.startIndex, offsetBy: 8)..<close]), ms.isFinite {
                lyrics.offset = ms / 1000; continue
            }
            let range = NSRange(line.startIndex..., in: line)
            let matches = expression.matches(in: line, range: range)
            if matches.isEmpty {
                if line.hasPrefix("[ar:") || line.hasPrefix("[ti:") || line.hasPrefix("[al:") || line.hasPrefix("[by:") { continue }
                lyrics.lines.append(.init(text: line))
                if line.hasPrefix("[") { warnings.append("未识别的时间标签已保留为文字，可手工修正。") }
            } else {
                let last = matches.last!
                // NSRegularExpression uses UTF-16 offsets, while String indices count graphemes.
                guard let lastRange = Range(last.range, in: line) else { continue }
                let words = String(line[lastRange.upperBound...])
                for match in matches {
                    let ns = line as NSString
                    let minutes = Double(ns.substring(with: match.range(at: 1))) ?? 0
                    let seconds = Double(ns.substring(with: match.range(at: 2))) ?? 0
                    guard minutes.isFinite, seconds.isFinite, seconds < 60, (minutes * 60 + seconds).isFinite else { warnings.append("时间标签无效，请手工修正。"); lyrics.lines.append(.init(text: words)); continue }
                    lyrics.lines.append(.init(text: words, time: minutes * 60 + seconds))
                }
            }
        }
        if lyrics.lines.allSatisfy({ $0.time != nil }) { lyrics.lines.sort { $0.time! < $1.time! } }
        return Result(lyrics: lyrics, warnings: Array(Set(warnings)).sorted())
    }
}

public enum BackupMode: String, Codable, CaseIterable, Sendable {
    case full, slim, custom
    public var label: String { self == .full ? "完整" : self == .slim ? "精简" : "自定义" }
}

public enum ProjectRules {
    public static func isExportMetadata(_ path: String) -> Bool {
        ["exports/queue.json", "exports/history.json"].contains(path.lowercased())
    }
    public static func safePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":")
            && !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasSuffix(".") && !$0.hasSuffix(" ") }
    }
    /// Media may never replace project metadata. Resolved paths also reject symlink escapes.
    public static func mediaURL(_ path: String, root: URL) throws -> URL {
        guard safePath(path), !isExportMetadata(path),
              path.hasPrefix("media/") || path.hasPrefix("exports/") else { throw StudioError("素材必须位于工程 media 或 exports 目录内，不能覆盖索引。") }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let direct = base.appendingPathComponent(path).standardizedFileURL
        let target = direct.resolvingSymlinksInPath()
        guard target.path == direct.path, target.path.hasPrefix(base.path + "/media/") || target.path.hasPrefix(base.path + "/exports/") else { throw StudioError("素材路径超出工程媒体目录或包含符号链接。") }
        return target
    }
    public static func validate(_ project: StudioProject) throws {
        guard project.schemaVersion == 1, project.revision >= 1 else { throw StudioError("工程格式版本不兼容，请更新 App。") }
        let paths = project.assets.map { $0.path.precomposedStringWithCanonicalMapping.lowercased() }
        guard Set(project.assets.map(\.id)).count == project.assets.count,
              Set(paths).count == project.assets.count,
              Set(project.takes.map(\.id)).count == project.takes.count,
              Set(project.arrangements.map(\.id)).count == project.arrangements.count else {
            throw StudioError("工程包含重复 ID 或素材路径。")
        }
        let pathSet = Set(paths)
        for path in paths {
            let components = path.split(separator: "/")
            guard components.count > 1 else { throw StudioError("素材路径必须包含 media 目录。") }
            for count in 1..<components.count where pathSet.contains(components.prefix(count).joined(separator: "/")) {
                throw StudioError("素材文件与目录路径冲突。")
            }
        }
        guard project.arrangement != nil else { throw StudioError("当前伴奏版本缺失。") }
        let all = Set(project.assets.map(\.id))
        var required = Set<UUID>()
        for arrangement in project.arrangements {
            guard (-12...12).contains(arrangement.semitones), arrangement.lyrics.offset.isFinite,
                  arrangement.lyrics.lines.allSatisfy({ $0.time == nil || ($0.time!.isFinite && $0.time! >= 0) }) else {
                throw StudioError("伴奏或歌词参数无效。")
            }
            required.formUnion(arrangement.assetIDs)
        }
        for take in project.takes {
            let sequences = take.segments.compactMap(\.sequence)
            guard sequences.allSatisfy({ $0 >= 0 && $0 < Int32.max }), Set(sequences).count == sequences.count else {
                throw StudioError("录制片段的顺序编号无效或重复。")
            }
            guard project.arrangement(for: take) != nil, (-12...12).contains(take.semitones),
                  Set(take.segments.map(\.id)).count == take.segments.count else { throw StudioError("Take 的伴奏版本或片段信息无效。") }
            required.formUnion(take.assetIDs)
            for segment in take.segments {
                guard segment.duration.timescale > 0, segment.duration.seconds >= 0,
                      segment.songStart.timescale > 0, segment.hostStart.timescale > 0,
                      segment.songStart.seconds >= 0,
                      [segment.inputLatency, segment.outputLatency].allSatisfy({ $0.isFinite && $0 >= 0 }),
                      [segment.audioFirstPTS, segment.videoFirstPTS].compactMap({ $0 }).allSatisfy({ $0.timescale > 0 }) else { throw StudioError("片段时间信息无效。") }
            }
        }
        required.formUnion([project.edit.visualAssetID, project.song.coverAssetID].compactMap { $0 })
        guard required.isSubset(of: all) else { throw StudioError("工程缺少编辑所需的素材，不能恢复。") }
        let takeIDs = Set(project.takes.map(\.id))
        guard project.edit.referencedTakeIDs.isSubset(of: takeIDs),
              project.edit.selectedTakeID == nil || takeIDs.contains(project.edit.selectedTakeID!) else {
            throw StudioError("编辑引用的 Take 缺失。")
        }
        let edit = project.edit
        guard [edit.subtitleStart, edit.visualSongStart, edit.visualOffset, edit.vocalGain, edit.backingGain, edit.bassDB, edit.presenceDB, edit.reverb, edit.highPassHz,
               edit.syncOffset, edit.trimStart, edit.aspect, edit.subtitleStyle.size, edit.subtitleStyle.verticalPosition, edit.subtitleStyle.outlineWidth].allSatisfy(\.isFinite),
              (8...160).contains(edit.subtitleStyle.size), (0...1).contains(edit.subtitleStyle.verticalPosition),
              (0...6).contains(edit.subtitleStyle.outlineWidth),
              (0...2).contains(edit.vocalGain), (0...2).contains(edit.backingGain),
              (0...100).contains(edit.reverb), (20...1000).contains(edit.highPassHz),
              edit.aspect >= 0.4, edit.aspect <= 2.5, edit.trimStart >= 0, edit.subtitleStart >= 0,
              edit.subtitleEnd == nil || (edit.subtitleEnd!.isFinite && edit.subtitleEnd! > edit.subtitleStart),
              edit.trimEnd == nil || (edit.trimEnd!.isFinite && edit.trimEnd! > edit.trimStart),
              edit.segmentStartOverrides.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw StudioError("编辑参数或时间轴超出安全范围。")
        }
        for asset in project.assets {
            guard safePath(asset.path), !isExportMetadata(asset.path),
                  asset.path.hasPrefix("media/") || (asset.path.hasPrefix("exports/") && asset.role == .export), asset.bytes >= 0,
                  asset.duration.timescale > 0, asset.duration.value >= 0,
                  asset.sampleRate == nil || (asset.sampleRate!.isFinite && asset.sampleRate! > 0),
                  asset.channels == nil || asset.channels! > 0,
                  asset.sha256.utf8.count == 64, asset.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw StudioError("素材路径、大小或校验码无效。")
            }
        }
    }

    public static func backupProject(_ project: StudioProject, mode: BackupMode, selected: Set<UUID> = [], includeExports: Bool = false,
                                     selectedExportPaths: Set<String>? = nil) throws -> StudioProject {
        try validate(project)
        let chosenExports = selectedExportPaths.map { Set($0.map { $0.precomposedStringWithCanonicalMapping.lowercased() }) }
        if mode == .custom, includeExports, let chosenExports {
            let available = Set(project.assets.filter { $0.role == .export }.map { $0.path.precomposedStringWithCanonicalMapping.lowercased() })
            guard chosenExports.isSubset(of: available) else { throw StudioError("选择的导出成品已不存在，请重新选择后打包。") }
        }
        var result = project
        if mode == .full {
            if !includeExports {
                var required = project.arrangements.reduce(into: Set<UUID>()) { $0.formUnion($1.assetIDs) }
                project.takes.forEach { required.formUnion($0.assetIDs) }
                required.formUnion([project.edit.visualAssetID, project.song.coverAssetID].compactMap { $0 })
                result.assets.removeAll { $0.role == .export && !required.contains($0.id) }
            }
            try validate(result)
            return result
        }
        var keep = project.edit.referencedTakeIDs
        if let id = project.edit.selectedTakeID { keep.insert(id) }
        if mode == .custom { keep.formUnion(selected) }
        guard keep.isSubset(of: Set(project.takes.map(\.id))) else { throw StudioError("自定义备份选择的 Take 已不存在，请重新选择。") }
        result.takes = project.takes.filter { keep.contains($0.id) }
        // Follow promotion links only when their targets are retained; this is bookkeeping, not a media dependency.
        for i in result.takes.indices {
            if let promoted = result.takes[i].promotedTakeID, !keep.contains(promoted) { result.takes[i].promotedTakeID = nil }
        }
        let arrangementIDs = Set(result.takes.map(\.arrangementID)).union([project.arrangementID])
        result.arrangements = project.arrangements.filter { arrangementIDs.contains($0.id) }
        var assets = result.arrangements.reduce(into: Set<UUID>()) { $0.formUnion($1.assetIDs) }
        result.takes.forEach { assets.formUnion($0.assetIDs) }
        assets.formUnion([project.edit.visualAssetID, project.song.coverAssetID].compactMap { $0 })
        if mode == .custom && includeExports {
            assets.formUnion(project.assets.filter { asset in
                asset.role == .export && (chosenExports == nil || chosenExports!.contains(asset.path.precomposedStringWithCanonicalMapping.lowercased()))
            }.map(\.id))
        }
        result.assets = project.assets.filter { assets.contains($0.id) }
        try validate(result)
        return result
    }
}

public struct DiskBudget: Equatable {
    public var warningBytes: Int64
    public var stopBytes: Int64
    public init(bytesPerSecond: Double, finalizationBytes: Int64 = 16 * 1024 * 1024) {
        guard bytesPerSecond.isFinite, bytesPerSecond < Double(Int64.max / 120) else {
            stopBytes = .max; warningBytes = .max; return
        }
        let rate = max(1, bytesPerSecond)
        let (stop, overflow) = max(0, finalizationBytes).addingReportingOverflow(Int64(rate * 20))
        stopBytes = overflow ? .max : stop
        let (warning, warningOverflow) = stopBytes.addingReportingOverflow(Int64(rate * 100))
        warningBytes = warningOverflow ? .max : warning
    }
    public func shouldStop(available: Int64) -> Bool { available <= stopBytes }
}

public enum RecordingState: String, Codable, Sendable {
    case idle, preflight, ready, countdown, recording, interrupted, finalizing, saved, recoverableError
    public func canTransition(to next: Self) -> Bool {
        switch (self, next) {
        case (.idle, .preflight), (.saved, .preflight), (.recoverableError, .preflight),
             (.ready, .preflight), (.interrupted, .preflight), (.ready, .idle), (.interrupted, .idle),
             (.preflight, .ready), (.ready, .countdown), (.countdown, .recording),
             (.recording, .interrupted), (.interrupted, .countdown),
             (.recording, .finalizing), (.interrupted, .finalizing),
             (.finalizing, .saved), (.countdown, .ready): return true
        default: return next == .recoverableError || next == self
        }
    }
}

public struct Capability: Equatable, Sendable {
    public var available: Bool
    public var explanation: String
    public init(available: Bool, explanation: String) { self.available = available; self.explanation = explanation }
}
public protocol AISeparationProvider {
    var capability: Capability { get }
    func separate(source: URL, destination: URL) async throws -> (vocal: URL, backing: URL)
}
public protocol LyricsAlignmentProvider {
    var capability: Capability { get }
    func align(audio: URL, lyrics: Lyrics) async throws -> Lyrics
}
public protocol PitchCorrectionProvider {
    var capability: Capability { get }
    func correct(source: URL, destination: URL, semitones: Int) async throws
}
public struct UnavailableAI: AISeparationProvider, LyricsAlignmentProvider, PitchCorrectionProvider {
    public init() {}
    public var capability: Capability { .init(available: false, explanation: "尚未集成并验证本地模型；请导入现成伴奏、手工标记歌词，使用基础混音。不会上传素材。") }
    public func separate(source: URL, destination: URL) async throws -> (vocal: URL, backing: URL) { throw StudioError(capability.explanation) }
    public func align(audio: URL, lyrics: Lyrics) async throws -> Lyrics { throw StudioError(capability.explanation) }
    public func correct(source: URL, destination: URL, semitones: Int) async throws { throw StudioError(capability.explanation) }
}

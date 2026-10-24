import Foundation

/// Shared by Files import, pasted text and the editor's explicit Save action.
public enum LyricsDocument {
    public static let maximumBytes = 2 * 1024 * 1024

    public static func read(_ url: URL) throws -> String {
        guard ["txt", "lrc"].contains(url.pathExtension.lowercased()) else { throw StudioError("请选择 .txt 或 .lrc 歌词文件。") }
        guard try FileIntegrity.size(url) <= Int64(maximumBytes) else { throw StudioError("歌词文件超过 2 MB，请选择纯文本文件。") }
        return try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> String {
        guard !data.isEmpty, data.count <= maximumBytes else { throw StudioError("歌词文件为空或超过 2 MB。") }
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) { text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        else if data.starts(with: [0xFE, 0xFF]) { text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        else { text = String(data: data, encoding: .utf8) }
        guard let text else { throw StudioError("无法读取歌词编码，请将文件保存为 UTF-8 或带 BOM 的 UTF-16 纯文本。") }
        return try validate(text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")))
    }

    public static func validate(_ text: String) throws -> String {
        guard text.utf8.count <= maximumBytes else { throw StudioError("歌词超过 2 MB，请减少文字。") }
        // Foundation's controlCharacters also includes format scalars such as the ZWJ
        // inside emoji. Reject binary control codes, not valid Unicode lyric text.
        guard !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && !CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw StudioError("文件包含非文本内容，请选择纯文本 TXT 或 LRC。")
        }
        return text
    }

    /// Preserve offset and negative effective times while reopening an existing draft.
    /// Lyrics.lrc() is an export format that bakes/clamps offset; it must not be used here.
    public static func editableText(_ lyrics: Lyrics) -> String {
        var unshifted = lyrics; unshifted.offset = 0
        let header = lyrics.offset == 0 ? "" : "[offset:\(lyrics.offset * 1000)]\n"
        return header + unshifted.lrc()
    }

    public static func applying(_ lyrics: Lyrics, to project: StudioProject, arrangementID: UUID) throws -> StudioProject {
        guard !project.archived, let index = project.arrangements.firstIndex(where: { $0.id == arrangementID }) else {
            throw StudioError("歌词对应的伴奏版本已变化，请重新打开歌词编辑器。")
        }
        var updated = project
        updated.arrangements[index].lyrics = lyrics
        updated.touch()
        try ProjectRules.validate(updated)
        return updated
    }
}

import Foundation

/// A new Take is a new timeline, never an implicit continuation of practice/playback.
public enum RecordingOrigin: Equatable, Sendable {
    case fullTake
    case practice(position: Double)
    case section(start: Double)
    case recovery(savedEnd: Double)

    public static func session(practice: Bool, playbackPosition: Double, sectionStart: Double? = nil, recoveringEnd: Double? = nil) -> RecordingOrigin {
        if let recoveringEnd { return .recovery(savedEnd: recoveringEnd) }
        if practice { return .practice(position: playbackPosition) }
        if let sectionStart { return .section(start: sectionStart) }
        return .fullTake
    }

    public func position(duration: Double) throws -> Double {
        guard duration.isFinite, duration > 0 else { throw StudioError("伴奏时长无效，请重新导入音频。") }
        switch self {
        case .fullTake: return 0
        case .practice(let position):
            return position.isFinite && position >= 0 && position < duration ? position : 0
        case .section(let start):
            guard start.isFinite, start >= 0, start < duration else { throw StudioError("片段起点必须在伴奏时长内。") }
            return start
        case .recovery(let end):
            guard end.isFinite, end >= 0 else { throw StudioError("已保存片段的时间轴无效，请先检查 Take。") }
            return min(max(0, end - 3), max(0, duration - 0.001))
        }
    }
}

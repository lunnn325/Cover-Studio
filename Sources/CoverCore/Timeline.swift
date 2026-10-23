import Foundation

public struct TimelineRegion: Equatable, Sendable {
    public var segmentID: UUID
    public var sourceStart: Double
    public var start: Double
    public var duration: Double
}
public enum Timeline {
    public static func orderedSegments(_ segments: [RecordingSegment]) -> [RecordingSegment] {
        segments.enumerated().sorted {
            let left = $0.element.sequence ?? $0.offset, right = $1.element.sequence ?? $1.offset
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }
    /// New resumed material replaces the old overlap. Original segment media remains unchanged.
    public static func regions(take: Take, edit: EditGraph) -> [TimelineRegion] {
        var result: [TimelineRegion] = []
        for segment in orderedSegments(take.segments) {
            let start = edit.segmentStartOverrides[segment.id] ?? segment.songStart.seconds
            guard start.isFinite, start >= 0, segment.duration.timescale > 0, segment.duration.seconds > 0 else { continue }
            result = result.compactMap { old in
                guard old.start < start else { return nil }
                var kept = old; kept.duration = min(old.duration, start - old.start)
                return kept.duration > 0 ? kept : nil
            }
            result.append(.init(segmentID: segment.id, sourceStart: 0, start: start, duration: segment.duration.seconds))
        }
        return result
    }
    public static func crop(_ region: TimelineRegion, range: ClosedRange<Double>, offset: Double = 0) -> TimelineRegion? {
        guard [region.start, region.sourceStart, region.duration, range.lowerBound, range.upperBound, offset].allSatisfy(\.isFinite),
              region.duration > 0, region.sourceStart >= 0 else { return nil }
        let start = region.start + offset
        let lo = max(range.lowerBound, start), hi = min(range.upperBound, start + region.duration)
        guard hi > lo else { return nil }
        return .init(segmentID: region.segmentID, sourceStart: region.sourceStart + lo - start,
                     start: lo - range.lowerBound, duration: hi - lo)
    }
    public static func range(take: Take, edit: EditGraph) throws -> ClosedRange<Double> {
        let end = edit.trimEnd ?? regions(take: take, edit: edit).map { $0.start + $0.duration }.max() ?? 0
        guard edit.trimStart.isFinite, edit.trimStart >= 0, end.isFinite, end > edit.trimStart else { throw StudioError("Take 尚无可用片段或裁剪区间为空。") }
        return edit.trimStart...end
    }
}

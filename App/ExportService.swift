import AVFoundation
import Combine
import CoverCore

@MainActor final class ExportService: ObservableObject {
    @Published var jobs: [ExportJob] = []
    @Published var working = false
    @Published var stage = ""
    @Published var shareURLs: [URL] = []
    @Published var failure: String?
    private var projectID: UUID?
    func load(root: URL, projectID: UUID, exportedAssets: [MediaAsset] = []) {
        guard !working else { return }
        self.projectID = projectID
        failure = nil
        do {
            let saved = try ExportCatalog.queue(root: root)
            if !saved.isEmpty {
                jobs = saved.map { var job = $0; if job.status == "运行中" { job.status = "中断"; job.error = "上次导出中断，可单独重试。" }; return job }
                shareURLs = jobs.filter { $0.status == "完成" }.compactMap { job in
                    guard let path = job.path, ExportCatalog.isOutputPath(path), let url = try? ProjectRules.mediaURL(path, root: root) else { return nil }
                    return FileManager.default.fileExists(atPath: url.path) ? url : nil
                }
            } else {
                jobs = Self.restoredJobs(assets: exportedAssets)
                shareURLs = jobs.compactMap { job in
                    guard let path = job.path, let url = try? ProjectRules.mediaURL(path, root: root), FileManager.default.fileExists(atPath: url.path) else { return nil }
                    return url
                }
            }
        } catch {
            jobs = []; shareURLs = []; failure = error.localizedDescription
        }
    }
    static func restoredJobs(assets: [MediaAsset]) -> [ExportJob] {
        assets.filter { $0.role == .export }.compactMap { asset in
            guard ExportCatalog.isOutputPath(asset.path), let variant = ExportCatalog.variant(for: asset.path) else { return nil }
            return ExportJob(variant: variant, status: "完成", path: asset.path)
        }
    }
    func run(project: StudioProject, root: URL, retry: ExportVariant? = nil) async {
        guard !working else { return }
        if projectID != project.id { load(root: root, projectID: project.id, exportedAssets: project.assets) }
        working = true; failure = nil; defer { working = false; stage = "" }
        projectID = project.id
        let target = root.appendingPathComponent("exports", isDirectory: true)
        var queueWritable = false
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            // Preserve this project's completed queue before replacing it. Never
            // copy an in-memory queue from another selected project into history.
            try ExportCatalog.rememberCompleted(ExportCatalog.queue(root: root), root: root)
            queueWritable = true
            guard let take = project.selectedTake else { throw StudioError("请先选择已保存的 Take。") }
            let hasVideo = project.edit.visualAssetID != nil || take.segments.contains { $0.videoAssetID != nil }
            var preset = project.exportPreset
            if let retry { preset.variants = [retry] }
            try preset.validate(lyrics: project.arrangement(for: take)?.lyrics ?? Lyrics(), hasVideo: hasVideo)
            let range = try Timeline.range(take: take, edit: project.edit), duration = range.upperBound - range.lowerBound
            let variants = ExportVariant.allCases.filter { preset.variants.contains($0) }
            if retry == nil { jobs = variants.map { ExportJob(variant: $0) }; shareURLs = [] }
            // Only generated intermediates live here; originals and completed outputs
            // are never part of this cleanup. A crash may leave a rebuildable cache.
            let scratchRoot = root.appendingPathComponent("cache/export-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratchRoot) }
            let mixURL = scratchRoot.appendingPathComponent("mix.caf")
            let cleanURL = scratchRoot.appendingPathComponent("clean.mp4")
            var renderedMix = false
            var renderedClean = false
            var background: URL?
            for variant in variants {
                if !jobs.contains(where: { $0.variant == variant }) { jobs.append(ExportJob(variant: variant)) }
                guard let index = jobs.firstIndex(where: { $0.variant == variant }) else { continue }
                jobs[index].status = "运行中"; jobs[index].error = nil; stage = variant.label
                try persist(root: root)
                do {
                    // Recheck before every item: completed videos remain on disk.
                    // Lyrics need no media render; photo/video failures cannot block stems.
                    if variant != .lyrics {
                        let videoOutput = variant == .cleanVideo || variant == .subtitledVideo
                        let estimateValue = duration * (48000 * 2 * 4 + (videoOutput ? 12_000_000 : 40_000)) + 64 * 1024 * 1024
                        guard estimateValue.isFinite, estimateValue < Double(Int64.max) else { throw StudioError("导出空间需求超出设备可用范围，请缩短区间。") }
                        let estimate = Int64(estimateValue)
                        guard try FileIntegrity.available(root) > estimate else { throw StudioError("剩余空间不足以安全生成此项。已完成项已保留；可减少输出、缩短区间或备份后释放其他工程空间。") }
                        if [.cleanVideo, .subtitledVideo, .mixAudio].contains(variant), !renderedMix {
                            stage = "正在离线混音"
                            // A prior failed attempt may have left a partial cache.
                            if FileManager.default.fileExists(atPath: mixURL.path) { try FileManager.default.removeItem(at: mixURL) }
                            try await Task.detached(priority: .userInitiated) { try MixRenderer.render(project: project, root: root, to: mixURL) }.value
                            renderedMix = true
                        }
                        if videoOutput, background == nil,
                           let id = project.edit.visualAssetID, let visual = project.asset(id), visual.role == .image {
                            stage = "正在生成照片画面"
                            let url = scratchRoot.appendingPathComponent(UUID().uuidString + "-photo.mov")
                            try await StillVideoRenderer.make(imageURL: root.appendingPathComponent(visual.path), duration: duration,
                                                              landscape: project.edit.aspect >= 1, to: url)
                            background = url
                        }
                    }
                    stage = variant.label
                    let suffix = variant == .lyrics ? ((project.arrangement(for: take)?.lyrics.isTimed == true) ? "lrc" : "txt") : (variant == .cleanVideo || variant == .subtitledVideo ? "mp4" : preset.audioFormat.rawValue)
                    let output = target.appendingPathComponent("\(UUID().uuidString)-\(variant.rawValue).\(suffix)")
                    switch variant {
                    case .lyrics:
                        let lyrics = project.arrangement(for: take)?.lyrics ?? Lyrics()
                        try lyrics.lrc().write(to: output, atomically: true, encoding: .utf8)
                    case .mixAudio: try await exportAudio(source: mixURL, output: output, format: preset.audioFormat)
                    case .dryVocal, .backing:
                        let scratch = scratchRoot.appendingPathComponent("\(UUID().uuidString).caf")
                        try await Task.detached(priority: .userInitiated) {
                            try MixRenderer.render(project: project, root: root, to: scratch, dryOnly: variant == .dryVocal, backingOnly: variant == .backing)
                        }.value
                        try await exportAudio(source: scratch, output: output, format: preset.audioFormat)
                    case .cleanVideo, .subtitledVideo:
                        if !renderedClean {
                            stage = "正在合成无字幕画面"
                            if FileManager.default.fileExists(atPath: cleanURL.path) { try FileManager.default.removeItem(at: cleanURL) }
                            let (composition, video) = try await VideoComposer.composition(project: project, root: root, mix: mixURL, backgroundVideo: background)
                            guard let video else { throw StudioError("没有可导出的视频画面，请先选择照片或补拍。") }
                            try await exportVideo(asset: composition, video: video, to: cleanURL, duration: duration)
                            renderedClean = true
                        }
                        if variant == .cleanVideo { try FileManager.default.copyItem(at: cleanURL, to: output) }
                        else {
                            stage = "正在按时间轴烧录字幕"
                            let base = AVURLAsset(url: cleanURL)
                            guard let track = try await base.loadTracks(withMediaType: .video).first else { throw StudioError("基础画面轨道不可读。") }
                            let size = try await track.load(.naturalSize)
                            let subtitles = try SubtitleFrameRenderer(project: project, size: size, duration: duration)
                            try await exportVideo(asset: base, video: subtitles.composition(asset: base), to: output, duration: duration)
                        }
                    }
                    guard try FileIntegrity.size(output) > 0 else { throw StudioError("输出文件为空，未报告成功。") }
                    jobs[index].status = "完成"; jobs[index].path = "exports/" + output.lastPathComponent
                    shareURLs.append(output)
                } catch { jobs[index].status = "失败"; jobs[index].error = error.localizedDescription }
                try persist(root: root)
            }
        } catch {
            failure = error.localizedDescription
            if jobs.isEmpty { jobs = [ExportJob(variant: retry ?? .cleanVideo, status: "失败", error: error.localizedDescription)] }
            else { for i in jobs.indices where jobs[i].status != "完成" { jobs[i].status = "失败"; jobs[i].error = error.localizedDescription } }
            if queueWritable { try? persist(root: root) }
        }
    }
    func previewMix(project: StudioProject, root: URL) async throws -> URL {
        guard !working else { throw StudioError("请等待当前导出完成。") }
        working = true; stage = "正在生成后期试听"; defer { working = false; stage = "" }
        let directory = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString + ".caf")
        try await Task.detached(priority: .userInitiated) { try MixRenderer.render(project: project, root: root, to: url) }.value
        return url
    }
    func prepareVideoPreview(project: StudioProject, root: URL, subtitles: Bool) async throws -> StudioPreview {
        guard !working else { throw StudioError("请等待当前处理完成。") }
        guard let take = project.selectedTake else { throw StudioError("请先选择 Take。") }
        let hasVideo = project.edit.visualAssetID != nil || take.segments.contains { $0.videoAssetID != nil }
        var preset = ExportPreset(); preset.variants = [subtitles ? .subtitledVideo : .cleanVideo]
        try preset.validate(lyrics: project.arrangement(for: take)?.lyrics ?? Lyrics(), hasVideo: hasVideo)
        let range = try Timeline.range(take: take, edit: project.edit), duration = range.upperBound - range.lowerBound
        let estimate = duration * (12_000_000 + 48000 * 2 * 4) + 64 * 1024 * 1024
        guard estimate.isFinite, estimate < Double(Int64.max), try FileIntegrity.available(root) > Int64(estimate) else {
            throw StudioError("空间不足以生成画面预览，请缩短裁剪区间或先处理存储。源素材未修改。")
        }
        working = true; stage = "正在准备画面预览"; defer { working = false; stage = "" }
        let cache = root.appendingPathComponent("cache/preview-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        do {
            try Task.checkCancellation()
            let mix = cache.appendingPathComponent("mix.caf")
            stage = "正在生成预览混音"
            try await Task.detached(priority: .userInitiated) { try MixRenderer.render(project: project, root: root, to: mix) }.value
            try Task.checkCancellation()
            var background: URL?
            if let id = project.edit.visualAssetID, let visual = project.asset(id), visual.role == .image {
                stage = "正在准备照片画面"
                let photo = cache.appendingPathComponent("photo.mov")
                try await StillVideoRenderer.make(imageURL: root.appendingPathComponent(visual.path), duration: duration,
                                                  landscape: project.edit.aspect >= 1, to: photo)
                background = photo
            }
            try Task.checkCancellation()
            let (composition, video) = try await VideoComposer.composition(project: project, root: root, mix: mix, backgroundVideo: background)
            guard let video else { throw StudioError("没有可预览的画面，请先选择照片或补拍。") }
            let item: AVPlayerItem
            if subtitles {
                stage = "正在准备字幕预览"
                let base = cache.appendingPathComponent("picture.mp4")
                try await exportVideo(asset: composition, video: video, to: base, duration: duration)
                try Task.checkCancellation()
                let asset = AVURLAsset(url: base)
                let renderer = try SubtitleFrameRenderer(project: project, size: video.renderSize, duration: duration)
                item = AVPlayerItem(asset: asset); item.videoComposition = renderer.composition(asset: asset)
            } else {
                // The native player can apply crop/mirror instructions directly.
                item = AVPlayerItem(asset: composition); item.videoComposition = video
            }
            try Task.checkCancellation()
            return StudioPreview(title: take.name + (subtitles ? " · 字幕画面预览" : " · 无字幕画面预览"), item: item, cacheDirectory: cache)
        } catch {
            try? FileManager.default.removeItem(at: cache)
            throw error
        }
    }
    private func exportAudio(source: URL, output: URL, format: AudioExportFormat) async throws {
        if format == .wav {
            try await Task.detached(priority: .userInitiated) {
                let reader = try AVAudioFile(forReading: source)
                let writer = try AVAudioFile(forWriting: output, settings: reader.processingFormat.settings)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 4096) else { throw StudioError("WAV 转换缓冲区不可用。") }
                while reader.framePosition < reader.length { try reader.read(into: buffer); try writer.write(from: buffer) }
            }.value
            return
        }
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetAppleM4A),
              session.supportedFileTypes.contains(.m4a) else { throw StudioError("设备不支持 M4A 音频编码，源文件已保留。") }
        session.outputFileType = .m4a; session.outputURL = output; try await complete(session)
    }
    private func complete(_ session: AVAssetExportSession) async throws {
        await withCheckedContinuation { continuation in session.exportAsynchronously { continuation.resume() } }
        guard session.status == .completed else { throw session.error ?? StudioError("导出未完成，原件和已完成项均已保留。") }
    }
    private func exportVideo(asset: AVAsset, video: AVVideoComposition, to output: URL, duration: Double) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality), session.supportedFileTypes.contains(.mp4) else {
            throw StudioError("当前设备不支持 MP4/H.264 导出。源文件已保留。")
        }
        session.videoComposition = video; session.outputURL = output; session.outputFileType = .mp4
        session.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600_000))
        session.shouldOptimizeForNetworkUse = true
        try await complete(session)
    }
    private func persist(root: URL) throws {
        try ExportCatalog.saveQueue(jobs, root: root)
    }
}

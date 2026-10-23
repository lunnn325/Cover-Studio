import AVFoundation
import UIKit
import CoverCore
import CoreImage
import CoreText

enum MixRenderer {
    static func render(project: StudioProject, root: URL, to output: URL, dryOnly: Bool = false, backingOnly: Bool = false) throws {
        guard let take = project.selectedTake, let arrangement = project.arrangement(for: take),
              let backingID = arrangement.backingAssetID, let backing = project.asset(backingID) else {
            throw StudioError("选中的 Take 或绑定伴奏缺失。")
        }
        let range = try Timeline.range(take: take, edit: project.edit)
        let sampleRate: Double = 48000
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let backingFile = try AVAudioFile(forReading: root.appendingPathComponent(backing.path))
        let engine = AVAudioEngine(), background = AVAudioPlayerNode(), pitch = AVAudioUnitTimePitch()
        let eq = AVAudioUnitEQ(numberOfBands: 3), reverb = AVAudioUnitReverb()
        let vocals = AVAudioMixerNode()
        engine.attach(background); engine.attach(pitch); engine.attach(eq); engine.attach(reverb); engine.attach(vocals)
        engine.connect(background, to: pitch, format: backingFile.processingFormat)
        engine.connect(pitch, to: engine.mainMixerNode, fromBus: 0, toBus: 0, format: nil)
        engine.connect(vocals, to: eq, format: format); engine.connect(eq, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, fromBus: 0, toBus: 1, format: format)
        pitch.pitch = Float(take.semitones * 100); pitch.rate = 1
        background.volume = dryOnly ? 0 : Float(backingOnly ? 1 : project.edit.backingGain)
        vocals.outputVolume = backingOnly ? 0 : Float(dryOnly ? 1 : project.edit.vocalGain)
        eq.bands[0].filterType = .highPass; eq.bands[0].frequency = Float(project.edit.highPassHz)
        eq.bands[1].filterType = .lowShelf; eq.bands[1].frequency = 200; eq.bands[1].gain = Float(project.edit.bassDB)
        eq.bands[2].filterType = .parametric; eq.bands[2].frequency = 3000; eq.bands[2].bandwidth = 1; eq.bands[2].gain = Float(project.edit.presenceDB)
        eq.bands.forEach { $0.bypass = dryOnly }
        reverb.loadFactoryPreset(.smallRoom); reverb.wetDryMix = dryOnly ? 0 : Float(project.edit.reverb)
        var nodes: [AVAudioPlayerNode] = [], files: [AVAudioFile] = []
        func schedule(_ file: AVAudioFile, player: AVAudioPlayerNode, source: Double, destination: Double, duration: Double) throws {
            let rate = file.processingFormat.sampleRate
            let start = AVAudioFramePosition(max(0, source) * rate)
            let count = min(file.length - start, AVAudioFramePosition(duration * rate))
            guard count > 0, count <= Int64(UInt32.max) else { return }
            player.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(count),
                                   at: AVAudioTime(sampleTime: AVAudioFramePosition(destination * rate), atRate: rate))
        }
        files.append(backingFile)
        if !dryOnly { try schedule(backingFile, player: background, source: range.lowerBound, destination: 0, duration: range.upperBound - range.lowerBound) }
        if !backingOnly {
            for region in Timeline.regions(take: take, edit: project.edit) {
                guard let cropped = Timeline.crop(region, range: range, offset: project.edit.syncOffset),
                      let segment = take.segments.first(where: { $0.id == region.segmentID }), let asset = project.asset(segment.vocalAssetID) else { continue }
                let file = try AVAudioFile(forReading: root.appendingPathComponent(asset.path)); files.append(file)
                let node = AVAudioPlayerNode(); nodes.append(node); engine.attach(node)
                engine.connect(node, to: vocals, fromBus: 0, toBus: vocals.nextAvailableInputBus, format: file.processingFormat)
                let lead = max(0, (segment.audioFirstPTS?.seconds ?? segment.hostStart.seconds) - segment.hostStart.seconds)
                let skip = max(0, lead - cropped.sourceStart)
                try schedule(file, player: node, source: max(0, cropped.sourceStart - lead),
                             destination: cropped.start + skip, duration: cropped.duration - skip)
            }
        }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        let writer = try AVAudioFile(forWriting: output, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)!
        try engine.start(); background.play(); nodes.forEach { $0.play() }
        defer { background.stop(); nodes.forEach { $0.stop() }; engine.stop(); engine.disableManualRenderingMode() }
        let total = AVAudioFramePosition((range.upperBound - range.lowerBound) * sampleRate)
        var retries = 0
        while engine.manualRenderingSampleTime < total {
            let frames = AVAudioFrameCount(min(Int64(buffer.frameCapacity), total - engine.manualRenderingSampleTime))
            let status = try engine.renderOffline(frames, to: buffer)
            switch status {
            case .success: try writer.write(from: buffer); retries = 0
            case .cannotDoInCurrentContext: retries += 1
            case .insufficientDataFromInputNode: throw StudioError("离线混音输入不足，源素材已保留。")
            case .error: throw StudioError("离线混音失败，源素材已保留。")
            @unknown default: throw StudioError("未知离线渲染状态。")
            }
            guard retries < 1000 else { throw StudioError("离线渲染暂时无法继续，请重试。") }
        }
        _ = files // Keep source files alive until offline rendering completes.
    }
}

enum VideoComposer {
    static func composition(project: StudioProject, root: URL, mix: URL?, raw: Bool = false, backgroundVideo: URL? = nil) async throws -> (AVMutableComposition, AVMutableVideoComposition?) {
        guard let take = project.selectedTake else { throw StudioError("请先选择 Take。") }
        let range = try Timeline.range(take: take, edit: project.edit)
        let duration = range.upperBound - range.lowerBound
        let composition = AVMutableComposition()
        var videoInstructions: [AVMutableVideoCompositionInstruction] = []
        let renderSize = project.edit.aspect >= 1 ? CGSize(width: 1920, height: 1080) : CGSize(width: 1080, height: 1920)
        let width = project.edit.aspect >= 1 ? renderSize.width : renderSize.height * project.edit.aspect
        let height = project.edit.aspect >= 1 ? renderSize.width / project.edit.aspect : renderSize.height
        let size = abs(project.edit.aspect - 1) < 0.0001 ? CGSize(width: 1080, height: 1080)
            : CGSize(width: floor(width / 2) * 2, height: floor(height / 2) * 2)
        func cm(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600_000) }
        func addVideo(url: URL, sourceStart: Double, at: Double, duration: Double) async throws {
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .video).first,
                  let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw StudioError("视频轨道不可读取。") }
            let timeRange = try await source.load(.timeRange)
            let mediaStart = max(sourceStart, timeRange.start.seconds)
            let skip = mediaStart - sourceStart
            let count = min(duration - skip, timeRange.end.seconds - mediaStart)
            guard count > 0 else { return }
            let destination = at + skip
            try target.insertTimeRange(CMTimeRange(start: cm(mediaStart), duration: cm(count)), of: source, at: cm(destination))
            let natural = try await source.load(.naturalSize), transform = try await source.load(.preferredTransform)
            let rect = CGRect(origin: .zero, size: natural).applying(transform)
            let scale = max(size.width / abs(rect.width), size.height / abs(rect.height))
            var final = transform.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: (size.width - abs(rect.width) * scale) / 2,
                                                 y: (size.height - abs(rect.height) * scale) / 2))
            if project.edit.mirrorExport { final = final.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0)) }
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: target); layer.setTransform(final, at: cm(destination))
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cm(destination), duration: cm(count)); instruction.layerInstructions = [layer]
            videoInstructions.append(instruction)
        }
        if let mix {
            let asset = AVURLAsset(url: mix)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw StudioError("混音轨道不可读取，未生成无声成品。")
            }
            let available = try await source.load(.timeRange)
            let count = min(duration, available.duration.seconds)
            guard count > 0 else { throw StudioError("混音轨道为空。") }
            try track.insertTimeRange(CMTimeRange(start: available.start, duration: cm(count)), of: source, at: .zero)
        }
        let visual = project.edit.visualAssetID.flatMap { project.asset($0) }
        if let backgroundVideo {
            try await addVideo(url: backgroundVideo, sourceStart: 0, at: 0, duration: duration)
        } else if let visual, visual.role == .video {
            let sourceDuration = visual.duration.seconds
            let visualStart = project.edit.visualSongStart + project.edit.visualOffset
            let lo = max(range.lowerBound, visualStart), hi = min(range.upperBound, visualStart + sourceDuration)
            guard hi > lo else { throw StudioError("补拍画面和当前裁剪区间没有重叠，请修正画面偏移。") }
            try await addVideo(url: root.appendingPathComponent(visual.path), sourceStart: lo - visualStart, at: lo - range.lowerBound, duration: hi - lo)
        } else {
            for region in Timeline.regions(take: take, edit: project.edit) {
                guard let cropped = Timeline.crop(region, range: range), let segment = take.segments.first(where: { $0.id == region.segmentID }) else { continue }
                if let id = segment.videoAssetID, let asset = project.asset(id) {
                    let lead = max(0, (segment.videoFirstPTS?.seconds ?? segment.hostStart.seconds) - segment.hostStart.seconds)
                    let skip = max(0, lead - cropped.sourceStart)
                    try await addVideo(url: root.appendingPathComponent(asset.path), sourceStart: max(0, cropped.sourceStart - lead),
                                       at: cropped.start + skip, duration: cropped.duration - skip)
                }
            }
        }
        if raw {
            for region in Timeline.regions(take: take, edit: project.edit) {
                guard let cropped = Timeline.crop(region, range: range, offset: project.edit.syncOffset),
                      let segment = take.segments.first(where: { $0.id == region.segmentID }), let asset = project.asset(segment.vocalAssetID) else { continue }
                let sourceAsset = AVURLAsset(url: root.appendingPathComponent(asset.path))
                if let source = try await sourceAsset.loadTracks(withMediaType: .audio).first,
                   let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    let lead = max(0, (segment.audioFirstPTS?.seconds ?? segment.hostStart.seconds) - segment.hostStart.seconds)
                    let sourceRange = try await source.load(.timeRange)
                    let desired = max(0, cropped.sourceStart - lead)
                    let sourceStart = max(sourceRange.start.seconds, desired)
                    let skip = max(0, lead - cropped.sourceStart) + sourceStart - desired
                    let count = min(cropped.duration - skip, sourceRange.end.seconds - sourceStart)
                    if count > 0 { try target.insertTimeRange(CMTimeRange(start: cm(sourceStart), duration: cm(count)), of: source, at: cm(cropped.start + skip)) }
                }
            }
        }
        guard !videoInstructions.isEmpty else { return (composition, nil) }
        videoInstructions.sort { $0.timeRange.start < $1.timeRange.start }
        // Explicit empty instructions make missing visual ranges visible rather than invalidating the composition.
        var covered = CMTime.zero, instructions: [AVVideoCompositionInstructionProtocol] = []
        for instruction in videoInstructions {
            if instruction.timeRange.start > covered {
                let gap = AVMutableVideoCompositionInstruction(); gap.timeRange = CMTimeRange(start: covered, end: instruction.timeRange.start)
                gap.backgroundColor = UIColor.black.cgColor; gap.layerInstructions = []; instructions.append(gap)
            }
            instructions.append(instruction); covered = instruction.timeRange.end
        }
        if covered < cm(duration) {
            let gap = AVMutableVideoCompositionInstruction(); gap.timeRange = CMTimeRange(start: covered, end: cm(duration))
            gap.backgroundColor = UIColor.black.cgColor; gap.layerInstructions = []; instructions.append(gap)
        }
        let video = AVMutableVideoComposition(); video.renderSize = size; video.frameDuration = CMTime(value: 1, timescale: 30)
        video.instructions = instructions
        return (composition, video)
    }

}

/// A clean video is composed first so crop, mirror and resumed segments are fixed.
/// Subtitles use frame timestamps instead of a process-wide Core Animation tree.
/// Only the current line's small raster is cached, even for long lyric files.
final class SubtitleFrameRenderer: @unchecked Sendable {
    private let cues: [SubtitleCue]
    private let style: SubtitleStyle
    private let size: CGSize
    private let lock = NSLock()
    private var cachedIndex: Int?
    private var cachedImage: CIImage?
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(project: StudioProject, size: CGSize, duration: Double) throws {
        guard let take = project.selectedTake, let lyrics = project.arrangement(for: take)?.lyrics else { throw StudioError("缺少歌词时间轴。") }
        self.cues = try Timeline.subtitleCues(lyrics: lyrics, edit: project.edit, duration: duration)
        self.style = project.edit.subtitleStyle; self.size = size
    }
    func composition(asset: AVAsset) -> AVVideoComposition {
        AVVideoComposition(asset: asset, applyingCIFiltersWithHandler: { [self] request in
            do {
                let source = request.sourceImage
                let overlay = try image(at: request.compositionTime.seconds)
                request.finish(with: overlay?.composited(over: source).cropped(to: source.extent) ?? source, context: context)
            } catch { request.finish(with: error) }
        })
    }
    private func image(at seconds: Double) throws -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        // Binary search avoids a per-frame scan through a whole song's lyrics.
        var lo = 0, hi = cues.count
        while lo < hi {
            let middle = (lo + hi) / 2
            if cues[middle].start <= seconds { lo = middle + 1 } else { hi = middle }
        }
        guard lo > 0, seconds < cues[lo - 1].end else { return nil }
        let index = lo - 1
        if cachedIndex == index { return cachedImage }
        let width = Int(ceil(size.width * 0.88)), height = Int(ceil(style.size * 3 + 12))
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw StudioError("字幕缓冲区不可用，未导出假字幕。")
        }
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafePointer(to: &alignment) { pointer in
            let setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)
            return CTParagraphStyleCreate([setting], 1)
        }
        let color = style.whiteText ? CGColor(gray: 1, alpha: 1) : CGColor(red: 1, green: 1, blue: 0, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(style.fontName as CFString, style.size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph
        ]
        let text = NSAttributedString(string: cues[index].text, attributes: attributes)
        let setter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: CGRect(x: 6, y: 6, width: CGFloat(width - 12), height: CGFloat(height - 12)), transform: nil)
        if style.shadow { bitmap.setShadow(offset: CGSize(width: 0, height: -2), blur: 3, color: CGColor(gray: 0, alpha: 1)) }
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: text.length), path, nil), bitmap)
        guard let raster = bitmap.makeImage() else { throw StudioError("字幕图像生成失败。") }
        cachedIndex = index
        cachedImage = CIImage(cgImage: raster).transformed(by: CGAffineTransform(translationX: size.width * 0.06, y: size.height * style.verticalPosition))
        return cachedImage
    }
}

enum StillVideoRenderer {
    static func make(imageURL: URL, duration: Double, landscape: Bool, to output: URL) async throws {
        guard duration.isFinite, duration > 0, let sourceImage = UIImage(contentsOfFile: imageURL.path) else { throw StudioError("背景照片无法读取或视频时长为空。") }
        let size = landscape ? CGSize(width: 1920, height: 1080) : CGSize(width: 1080, height: 1920)
        // Apply EXIF orientation at the video size; a default screen-scale renderer
        // at a large source-photo size can otherwise allocate hundreds of MB.
        let rasterFormat = UIGraphicsImageRendererFormat(); rasterFormat.scale = 1; rasterFormat.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: rasterFormat).image { context in
            UIColor.black.setFill(); context.fill(CGRect(origin: .zero, size: size))
            let scale = max(size.width / sourceImage.size.width, size.height / sourceImage.size.height)
            sourceImage.draw(in: CGRect(x: (size.width - sourceImage.size.width * scale) / 2,
                                       y: (size.height - sourceImage.size.height * scale) / 2,
                                       width: sourceImage.size.width * scale, height: sourceImage.size.height * scale))
        }
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                  kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height), kCVPixelBufferCGImageCompatibilityKey as String: true,
                  kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        guard writer.canAdd(input) else { throw StudioError("不支持照片视频编码。") }
        writer.add(input); guard writer.startWriting() else { throw writer.error ?? StudioError("照片视频写入失败。") }
        writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else { writer.cancelWriting(); throw StudioError("照片视频缓冲区不可用。") }
        CVPixelBufferLockBaseAddress(pixel, [])
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                     bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue), let cg = image.cgImage else {
            CVPixelBufferUnlockBaseAddress(pixel, []); throw StudioError("照片图像转换失败。")
        }
        context.setFillColor(UIColor.black.cgColor); context.fill(CGRect(origin: .zero, size: size))
        let scale = max(size.width / image.size.width, size.height / image.size.height)
        context.draw(cg, in: CGRect(x: (size.width - image.size.width * scale) / 2, y: (size.height - image.size.height * scale) / 2, width: image.size.width * scale, height: image.size.height * scale))
        CVPixelBufferUnlockBaseAddress(pixel, [])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var frame: Int64 = 0, finished = false
            let total = Int64(ceil(duration * 30))
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "studio.still")) {
                guard !finished else { return }
                while input.isReadyForMoreMediaData && frame < total {
                    guard adaptor.append(pixel, withPresentationTime: CMTime(value: frame, timescale: 30)) else {
                        finished = true; writer.cancelWriting(); continuation.resume(throwing: writer.error ?? StudioError("照片视频编码失败。")); return
                    }
                    frame += 1
                }
                if frame >= total {
                    finished = true; input.markAsFinished()
                    writer.finishWriting {
                        if writer.status == .completed { continuation.resume() }
                        else { continuation.resume(throwing: writer.error ?? StudioError("照片视频未完成。")) }
                    }
                }
            }
        }
    }
}

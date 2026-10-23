import AVFoundation
import CoverCore

struct CapturedChunk {
    var vocalURL: URL
    var videoURL: URL?
    var songStart: Double
    var anchor: CMTime
    var duration: CMTime
    var audioPTS: CMTime?
    var videoPTS: CMTime?
    var playbackHost: UInt64
    var sampleRate: Double
    var channels: Int
    var route: String
    var inputLatency: Double
    var outputLatency: Double
}

/// Owns the only microphone capture path. All writer state and capture callbacks use one serial queue.
final class CapturePipeline: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "studio.capture", qos: .userInitiated)
    var onChunk: ((CapturedChunk, @escaping (Result<Void, Error>) -> Void) -> Void)?
    var onError: ((Error) -> Void)?
    /// Linear RMS, 0...1; nil means this PCM layout cannot be interpreted safely.
    var onLevel: ((Float?) -> Void)?
    var onMonitorFormat: ((AVAudioFormat) -> Void)?
    var onMonitorSample: ((CMSampleBuffer) -> Void)?
    private var monitorFormat: AVAudioFormat?
    private var lastLevelHost: UInt64 = 0
    private var videoEnabled = false
    private var recording = false
    private var directory: URL?
    private var anchor = CMTime.invalid
    private var songStart: Double = 0
    private var playbackHost: UInt64 = 0
    private var current: ChunkWriter?
    private var pending = DispatchGroup()
    private var route = ""
    private var inputLatency: Double = 0
    private var outputLatency: Double = 0
    private var finalError: Error?

    func configure(video: Bool, front: Bool, landscape: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    if self.session.isRunning { self.session.stopRunning() }
                    self.session.beginConfiguration()
                    self.session.inputs.forEach { self.session.removeInput($0) }
                    self.session.outputs.forEach { self.session.removeOutput($0) }
                    self.session.automaticallyConfiguresApplicationAudioSession = false
                    self.session.usesApplicationAudioSession = true
                    self.session.sessionPreset = video && self.session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
                    guard let microphone = AVCaptureDevice.default(for: .audio) else { throw StudioError("没有可用麦克风。") }
                    let audioInput = try AVCaptureDeviceInput(device: microphone)
                    guard self.session.canAddInput(audioInput) else { throw StudioError("麦克风暂时不可用，请关闭其他录音应用后重试。") }
                    self.session.addInput(audioInput)
                    let audio = AVCaptureAudioDataOutput()
                    guard self.session.canAddOutput(audio) else { throw StudioError("不能创建人声录音输出。") }
                    self.session.addOutput(audio); audio.setSampleBufferDelegate(self, queue: self.queue)
                    if video {
                        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back) else { throw StudioError("摄像头不可用，请切换纯音频。") }
                        let cameraInput = try AVCaptureDeviceInput(device: camera)
                        guard self.session.canAddInput(cameraInput) else { throw StudioError("摄像头被占用，请切换纯音频或稍后重试。") }
                        self.session.addInput(cameraInput)
                        let output = AVCaptureVideoDataOutput()
                        output.alwaysDiscardsLateVideoFrames = true
                        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                        guard self.session.canAddOutput(output) else { throw StudioError("不能创建视频输出。") }
                        self.session.addOutput(output); output.setSampleBufferDelegate(self, queue: self.queue)
                        if let connection = output.connection(with: .video) {
                            if connection.isVideoRotationAngleSupported(landscape ? 0 : 90) { connection.videoRotationAngle = landscape ? 0 : 90 }
                            if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false }
                        }
                    }
                    self.videoEnabled = video
                    self.monitorFormat = nil
                    self.session.commitConfiguration(); self.session.startRunning()
                    continuation.resume()
                } catch {
                    self.session.commitConfiguration(); continuation.resume(throwing: error)
                }
            }
        }
    }

    func begin(directory: URL, songStart: Double, host: UInt64, route: String, inputLatency: Double, outputLatency: Double) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.session.isRunning, !self.recording else { continuation.resume(throwing: StudioError("录制会话尚未就绪。")); return }
                self.directory = directory; self.songStart = songStart; self.playbackHost = host
                self.anchor = CMTime(seconds: AVAudioTime.seconds(forHostTime: host), preferredTimescale: 1_000_000_000)
                self.route = route; self.inputLatency = inputLatency; self.outputLatency = outputLatency
                self.finalError = nil
                self.current = nil; self.recording = true
                continuation.resume()
            }
        }
    }
    func end() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.recording = false
                if let writer = self.current { self.finish(writer); self.current = nil }
                self.pending.notify(queue: self.queue) {
                    if let error = self.finalError { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }
    }
    func shutDown() async {
        await withCheckedContinuation { continuation in
            queue.async { if self.session.isRunning { self.session.stopRunning() }; continuation.resume() }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let isAudio = output is AVCaptureAudioDataOutput
        if isAudio {
            if let description = CMSampleBufferGetFormatDescription(sampleBuffer),
               let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description), stream.pointee.mFormatID == kAudioFormatLinearPCM {
                let format = AVAudioFormat(cmAudioFormatDescription: description)
                if monitorFormat?.isEqual(format) != true { monitorFormat = format; onMonitorFormat?(format) }
                onMonitorSample?(sampleBuffer)
            }
            let now = mach_absolute_time()
            if now - lastLevelHost >= AVAudioTime.hostTime(forSeconds: 0.1) {
                lastLevelHost = now; onLevel?(Self.rms(sampleBuffer))
            }
        }
        guard recording, let directory else { return }
        do {
            let originalPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let pts = session.masterClock.map { CMSyncConvertTime(originalPTS, from: $0, to: CMClockGetHostTimeClock()) } ?? originalPTS
            guard pts.isNumeric else { throw StudioError("采集时间戳无效，已停止以保护素材。") }
            guard pts >= anchor else { return }
            // Rotate on audio boundaries; already finalized chunks survive a crash or later failure.
            if let current, isAudio, CMTimeGetSeconds(pts - current.anchor) >= 8 {
                finish(current); self.current = nil
                songStart += CMTimeGetSeconds(pts - anchor); anchor = pts
            }
            if current == nil {
                current = try ChunkWriter(directory: directory, anchor: anchor, songStart: songStart, video: videoEnabled,
                                          host: playbackHost, route: route, inputLatency: inputLatency, outputLatency: outputLatency)
            }
            // Audio buffers contain many PCM samples. Preserve the per-sample duration;
            // using the buffer's total duration here stretches the encoded timeline.
            var timing = CMSampleTimingInfo()
            guard CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing) == noErr else {
                throw StudioError("无法读取采集时间信息。")
            }
            timing.presentationTimeStamp = pts
            if timing.decodeTimeStamp.isNumeric, let clock = session.masterClock {
                timing.decodeTimeStamp = CMSyncConvertTime(timing.decodeTimeStamp, from: clock, to: CMClockGetHostTimeClock())
            }
            var adjusted: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
                                                              sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &adjusted)
            guard status == noErr, let adjusted else { throw StudioError("音视频时间戳转换失败，已保护已完成片段。") }
            try current?.append(adjusted, audio: isAudio)
            // Asset metadata describes the encoder output (48 kHz mono), not the
            // input route, which may use a different sample rate/channel layout.
        } catch {
            recording = false; finalError = error; onError?(error)
        }
    }
    private static func rms(_ sample: CMSampleBuffer) -> Float? {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let format = pointer.pointee, flags = format.mFormatFlags
        guard format.mFormatID == kAudioFormatLinearPCM, flags & kAudioFormatFlagIsPacked != 0 else { return nil }
        let floating = flags & kAudioFormatFlagIsFloat != 0
        let signed = flags & kAudioFormatFlagIsSignedInteger != 0
        let big = flags & kAudioFormatFlagIsBigEndian != 0
        let bits = Int(format.mBitsPerChannel), width = bits / 8
        guard (floating && [32, 64].contains(bits)) || (signed && [16, 32].contains(bits)) else { return nil }
        let planar = flags & kAudioFormatFlagIsNonInterleaved != 0
        guard format.mChannelsPerFrame > 0,
              Int(format.mBytesPerFrame) == width * (planar ? 1 : Int(format.mChannelsPerFrame)) else { return nil }
        var length = 0, total = 0
        var bytes: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: &total,
                                          dataPointerOut: &bytes) == kCMBlockBufferNoErr,
              let bytes, length == total, total > 0, total % width == 0 else { return nil }
        let data = UnsafeRawPointer(bytes), count = total / width
        var squares: Double = 0
        for index in 0..<count {
            let offset = index * width
            let value: Double
            if floating && bits == 32 {
                let raw = data.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                value = Double(Float(bitPattern: big ? UInt32(bigEndian: raw) : UInt32(littleEndian: raw)))
            } else if floating {
                let raw = data.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                value = Double(bitPattern: big ? UInt64(bigEndian: raw) : UInt64(littleEndian: raw))
            } else if bits == 16 {
                let raw = data.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
                value = Double(Int16(bitPattern: big ? UInt16(bigEndian: raw) : UInt16(littleEndian: raw))) / 32768
            } else {
                let raw = data.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                value = Double(Int32(bitPattern: big ? UInt32(bigEndian: raw) : UInt32(littleEndian: raw))) / 2147483648
            }
            guard value.isFinite else { return nil }
            squares += value * value
        }
        return Float(min(1, sqrt(squares / Double(count))))
    }
    private func finish(_ writer: ChunkWriter) {
        pending.enter()
        writer.finish { result in
            self.queue.async {
                switch result {
                case .success(let chunk):
                    if let onChunk = self.onChunk {
                        onChunk(chunk) { result in
                            self.queue.async {
                                if case .failure(let error) = result {
                                    self.finalError = error; self.recording = false; self.onError?(error)
                                }
                                self.pending.leave()
                            }
                        }
                        return
                    }
                    let error = StudioError("片段未能登记到工程，原文件已保留。")
                    self.finalError = error; self.recording = false; self.onError?(error)
                case .failure(let error): self.finalError = error; self.onError?(error)
                }
                self.pending.leave()
            }
        }
    }
}

private final class ChunkWriter {
    let anchor: CMTime
    let songStart: Double
    let vocalURL: URL
    let videoURL: URL?
    let audioWriter: AVAssetWriter
    let audioInput: AVAssetWriterInput
    var videoWriter: AVAssetWriter?
    var videoInput: AVAssetWriterInput?
    var firstAudio: CMTime?
    var firstVideo: CMTime?
    var end: CMTime
    var sampleRate: Double = 48000
    var channels = 1
    let host: UInt64
    let route: String
    let inputLatency: Double
    let outputLatency: Double
    init(directory: URL, anchor: CMTime, songStart: Double, video: Bool, host: UInt64,
         route: String, inputLatency: Double, outputLatency: Double) throws {
        self.anchor = anchor; self.songStart = songStart; self.end = anchor
        self.host = host; self.route = route; self.inputLatency = inputLatency; self.outputLatency = outputLatency
        let token = UUID().uuidString
        vocalURL = directory.appendingPathComponent("media/\(token)-dry.m4a")
        videoURL = video ? directory.appendingPathComponent("media/\(token)-camera.mov") : nil
        audioWriter = try AVAssetWriter(outputURL: vocalURL, fileType: .m4a)
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 256000])
        audioInput.expectsMediaDataInRealTime = true
        guard audioWriter.canAdd(audioInput) else { throw StudioError("设备不支持干声编码。") }
        audioWriter.add(audioInput)
        guard audioWriter.startWriting() else { throw audioWriter.error ?? StudioError("无法开始写入人声。") }
    }
    func append(_ sample: CMSampleBuffer, audio: Bool) throws {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts >= anchor else { return }
        if audio {
            if firstAudio == nil { audioWriter.startSession(atSourceTime: pts) }
            guard audioInput.isReadyForMoreMediaData else { throw StudioError("人声写入跟不上采集，已停止以保护素材。") }
            guard audioInput.append(sample) else { throw audioWriter.error ?? StudioError("人声写入失败。") }
            if firstAudio == nil { firstAudio = pts }
        } else {
            if videoWriter == nil, let videoURL, let description = CMSampleBufferGetFormatDescription(sample) {
                let dimensions = CMVideoFormatDescriptionGetDimensions(description)
                let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
                writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
                writer.initialMovieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                       AVVideoWidthKey: Int(dimensions.width), AVVideoHeightKey: Int(dimensions.height)])
                input.expectsMediaDataInRealTime = true
                guard writer.canAdd(input) else { throw StudioError("设备不支持视频编码。") }
                writer.add(input)
                guard writer.startWriting() else { throw writer.error ?? StudioError("无法开始视频写入。") }
                writer.startSession(atSourceTime: pts); videoWriter = writer; videoInput = input
            }
            guard let videoWriter, let videoInput, videoInput.isReadyForMoreMediaData else { return }
            guard videoInput.append(sample) else { throw videoWriter.error ?? StudioError("视频写入失败。") }
            if firstVideo == nil { firstVideo = pts }
        }
        let duration = CMSampleBufferGetDuration(sample)
        end = max(end, pts + (duration.isNumeric && duration > .zero ? duration : CMTime(value: 1, timescale: audio ? 48000 : 30)))
    }
    func finish(_ completion: @escaping (Result<CapturedChunk, Error>) -> Void) {
        guard firstAudio != nil else {
            audioWriter.cancelWriting(); videoWriter?.cancelWriting()
            completion(.failure(StudioError("未收到可用麦克风数据。已保留写入文件供恢复。"))); return
        }
        let group = DispatchGroup()
        // Failed writers cannot accept markAsFinished/finishWriting; still finalize
        // the other stream so a video failure does not corrupt recoverable audio.
        if audioWriter.status == .writing {
            audioInput.markAsFinished(); group.enter(); audioWriter.finishWriting { group.leave() }
        }
        if let videoWriter, videoWriter.status == .writing {
            videoInput?.markAsFinished(); group.enter(); videoWriter.finishWriting { group.leave() }
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            guard self.audioWriter.status == .completed, self.videoWriter == nil || self.videoWriter?.status == .completed else {
                completion(.failure(self.audioWriter.error ?? self.videoWriter?.error ?? StudioError("片段封装未完成，源文件已保留。"))); return
            }
            completion(.success(.init(vocalURL: self.vocalURL, videoURL: self.firstVideo == nil ? nil : self.videoURL,
                songStart: self.songStart, anchor: self.anchor, duration: self.end - self.anchor,
                audioPTS: self.firstAudio, videoPTS: self.firstVideo, playbackHost: self.host,
                sampleRate: self.sampleRate, channels: self.channels, route: self.route,
                inputLatency: self.inputLatency, outputLatency: self.outputLatency)))
        }
    }
}

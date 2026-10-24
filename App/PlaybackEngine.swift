import AVFoundation
import Combine
import CoverCore

/// Receives the existing capture stream; it never owns a microphone/input node.
/// The lock protects scheduling against immediate route-change cancellation.
final class LiveInputMonitor: @unchecked Sendable {
    let node = AVAudioPlayerNode()
    var onFailure: ((String) -> Void)?
    private let lock = NSLock()
    private let completionQueue = DispatchQueue(label: "studio.monitor.completions")
    private var sourceFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var enabled = false
    private var queuedSeconds: Double = 0
    private var generation = UUID()

    func configure(_ source: AVAudioFormat, target: AVAudioFormat) -> Bool {
        lock.lock(); defer { lock.unlock() }
        enabled = false; node.stop(); generation = UUID(); queuedSeconds = 0
        sourceFormat = source; targetFormat = target
        converter = AVAudioConverter(from: source, to: target)
        return converter != nil
    }
    func setEnabled(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        enabled = value; generation = UUID(); queuedSeconds = 0
        node.stop()
        if value { node.volume = 0.5; node.play() }
    }
    func consume(_ sample: CMSampleBuffer) {
        lock.lock()
        guard enabled, let sourceFormat, let targetFormat, let converter else { lock.unlock(); return }
        var failure: String?
        let frames = CMSampleBufferGetNumSamples(sample)
        if frames <= 0 || frames > 8192 {
            failure = "耳返音频包过大或为空，已关闭耳返。"
        } else if let description = CMSampleBufferGetFormatDescription(sample),
                  sourceFormat.isEqual(AVAudioFormat(cmAudioFormatDescription: description)),
                  let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frames)),
                  let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(frames)) {
            input.frameLength = AVAudioFrameCount(frames)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList)
            do {
                guard status == noErr else { throw StudioError("无法复制耳返PCM数据。") }
                try converter.convert(to: output, from: input)
                let seconds = Double(output.frameLength) / targetFormat.sampleRate
                guard seconds > 0, queuedSeconds + seconds <= 0.10 else { throw StudioError("耳返缓存积压，已关闭耳返以避免明显延迟。") }
                queuedSeconds += seconds
                let token = generation
                node.scheduleBuffer(output, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    guard let self else { return }
                    // stop() may invoke completion synchronously. Never acquire
                    // the scheduling lock until that callback has returned.
                    self.completionQueue.async {
                        self.lock.lock(); defer { self.lock.unlock() }
                        if self.generation == token { self.queuedSeconds = max(0, self.queuedSeconds - seconds) }
                    }
                }
            } catch { failure = error.localizedDescription }
        } else { failure = "采集格式已变化或不支持耳返，已关闭耳返。" }
        if failure != nil { enabled = false; generation = UUID(); queuedSeconds = 0; node.stop() }
        lock.unlock()
        if let failure { onFailure?(failure) }
    }
}

@MainActor final class PlaybackEngine: ObservableObject {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let pitch = AVAudioUnitTimePitch()
    let liveMonitor = LiveInputMonitor()
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var playing = false
    @Published var gain: Double = 0.7 { didSet { player.volume = Float(gain) } }
    @Published var semitones = 0 { didSet { pitch.pitch = Float(semitones * 100); pitch.rate = 1 } }
    var loop: ClosedRange<Double>?
    private var file: AVAudioFile?
    private var base: Double = 0
    private var timer: Timer?
    private var generation = UUID()

    init() {
        engine.attach(player); engine.attach(pitch); engine.attach(liveMonitor.node)
        engine.connect(player, to: pitch, format: nil)
        engine.connect(pitch, to: engine.mainMixerNode, format: nil)
        player.volume = Float(gain)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    deinit { timer?.invalidate() }
    func load(_ url: URL, semitones: Int) throws {
        suspendEngine()
        let loaded = try AVAudioFile(forReading: url)
        guard loaded.length > 0, loaded.processingFormat.sampleRate > 0 else { throw StudioError("伴奏没有可播放的音频数据。") }
        // AVAudioPlayerNode's output format must match scheduled files. An engine
        // created before import may otherwise inherit a different hardware rate.
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(pitch)
        engine.connect(player, to: pitch, format: loaded.processingFormat)
        engine.connect(pitch, to: engine.mainMixerNode, fromBus: 0, toBus: 0, format: loaded.processingFormat)
        file = loaded
        duration = Double(loaded.length) / loaded.processingFormat.sampleRate
        self.semitones = semitones; position = 0
    }
    func prepare() throws {
        guard let file else { throw StudioError("请先导入可用伴奏。") }
        engine.prepare()
        if !engine.isRunning { try engine.start() }
        guard abs(pitch.inputFormat(forBus: 0).sampleRate - file.processingFormat.sampleRate) < 0.1,
              abs(pitch.outputFormat(forBus: 0).sampleRate - file.processingFormat.sampleRate) < 0.1 else {
            engine.stop(); throw StudioError("播放采样率发生变化，请重新打开伴奏后再试。")
        }
    }
    func configureMonitoring(format: AVAudioFormat) throws {
        guard !engine.isRunning, format.sampleRate > 0, format.channelCount > 0, format.channelCount <= 2,
              let target = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: format.channelCount),
              liveMonitor.configure(format, target: target) else { throw StudioError("当前PCM格式暂不支持安全耳返。") }
        engine.disconnectNodeOutput(liveMonitor.node)
        engine.connect(liveMonitor.node, to: engine.mainMixerNode, fromBus: 0, toBus: 1, format: target)
    }
    func setMonitoring(_ enabled: Bool) throws {
        if enabled { try prepare() }
        liveMonitor.setEnabled(enabled)
    }
    func activatePlaybackSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }
    @discardableResult
    func play(from seconds: Double? = nil, hostTime: UInt64? = nil) throws -> UInt64 {
        guard let file else { throw StudioError("请先导入可用伴奏。") }
        guard (seconds ?? position).isFinite else { throw StudioError("播放位置必须是有效秒数。") }
        stop(keepPosition: true)
        base = min(max(0, seconds ?? position), max(0, duration - 0.001)); position = base
        let start = AVAudioFramePosition(base * file.processingFormat.sampleRate)
        let available = max(0, file.length - start)
        guard available > 0, available <= Int64(UInt32.max) else { throw StudioError("播放区间为空或音频过长。") }
        try prepare()
        if let hostTime, hostTime <= mach_absolute_time() {
            throw StudioError("音频启动未赶上共同时间点，请重新检查后重试。已完成素材仍保留。")
        }
        generation = UUID(); let token = generation
        player.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(available), at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.playing = false; self.position = self.duration
                if let loop = self.loop, loop.lowerBound < loop.upperBound {
                    do { try self.play(from: loop.lowerBound) } catch { self.stop(keepPosition: true) }
                }
            }
        }
        let host = hostTime ?? (mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.1))
        player.play(at: AVAudioTime(hostTime: host)); playing = true
        return host
    }
    func stop(keepPosition: Bool = false) {
        tickPosition(); generation = UUID(); player.stop(); playing = false
        if !keepPosition { position = 0 }
    }
    func seek(_ seconds: Double) throws {
        guard seconds.isFinite else { throw StudioError("播放位置必须是有效秒数。") }
        let wasPlaying = playing
        stop(keepPosition: true); position = min(max(0, seconds), duration)
        if wasPlaying { try play(from: position) }
    }
    func suspendEngine() { liveMonitor.setEnabled(false); stop(keepPosition: true); engine.stop() }
    private func tickPosition() {
        guard playing, let render = player.lastRenderTime, let time = player.playerTime(forNodeTime: render), time.sampleRate > 0 else { return }
        position = min(duration, base + max(0, Double(time.sampleTime) / time.sampleRate))
    }
    private func tick() {
        tickPosition()
        if playing, let loop, position >= loop.upperBound {
            do { try play(from: loop.lowerBound) } catch { stop(keepPosition: true) }
        }
    }
}

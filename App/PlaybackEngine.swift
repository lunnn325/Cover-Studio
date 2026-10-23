import AVFoundation
import Combine
import CoverCore

@MainActor final class PlaybackEngine: ObservableObject {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let pitch = AVAudioUnitTimePitch()
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
        engine.attach(player); engine.attach(pitch)
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
        engine.connect(player, to: pitch, format: loaded.processingFormat)
        file = loaded
        duration = Double(loaded.length) / loaded.processingFormat.sampleRate
        self.semitones = semitones; position = 0
    }
    func prepare() throws {
        guard file != nil else { throw StudioError("请先导入可用伴奏。") }
        engine.prepare()
        if !engine.isRunning { try engine.start() }
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
    func suspendEngine() { stop(keepPosition: true); engine.stop() }
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

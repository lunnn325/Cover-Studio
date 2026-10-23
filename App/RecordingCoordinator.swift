import AVFoundation
import Combine
import UIKit
import CoverCore

@MainActor final class RecordingCoordinator: ObservableObject {
    @Published private(set) var state: RecordingState = .idle
    @Published var route = "未检查"
    @Published var routeConfirmed = false
    @Published var highQuality = "尚未检测"
    @Published var reason: String?
    @Published var countdown: Int?
    @Published var availableBytes: Int64 = 0
    @Published var warning: String?
    @Published var savedTakeID: UUID?
    @Published var video = true
    @Published var resumePosition: Double = 0
    @Published var inputs: [AVAudioSessionPortDescription] = []
    @Published var selectedInputUID = ""
    @Published private(set) var level: Float?
    @Published private(set) var monitoringEnabled = false
    @Published private(set) var monitoringAvailable = false
    @Published private(set) var monitoringExplanation = "耳返默认关闭；检查设备后可评估有线耳机路径。"
    let pipeline = CapturePipeline()
    weak var store: StudioStore?
    private let playback: PlaybackEngine
    private let repository: ProjectRepository
    private var projectID: UUID?
    private var takeID: UUID?
    private var observers: [NSObjectProtocol] = []
    private var monitor: Timer?
    private var practice = false
    private var stopping = false
    private var countdownTask: Task<Void, Never>?
    private var routeFingerprint = ""
    private var persistenceError: Error?
    private var observedBytesPerSecond: Double = 1_500_000
    private var monitoringFormat: AVAudioFormat?
    private var monitoringConfigured = false
    var isBusy: Bool { [.preflight, .ready, .countdown, .recording, .interrupted, .finalizing].contains(state) }
    var isCapturing: Bool { state == .recording || state == .countdown }
    var currentLyrics: Lyrics {
        guard let project = store?.selected else { return Lyrics() }
        if let takeID, let take = project.takes.first(where: { $0.id == takeID }) { return project.arrangement(for: take)?.lyrics ?? Lyrics() }
        return project.arrangement?.lyrics ?? Lyrics()
    }
    init(playback: PlaybackEngine, repository: ProjectRepository) {
        self.playback = playback; self.repository = repository
        pipeline.onChunk = { [weak self] chunk, done in
            Task { @MainActor in
                guard let self else { done(.failure(StudioError("录制工程已关闭，片段文件已保留。"))); return }
                do { try await self.commit(chunk); done(.success(())) }
                catch {
                    self.persistenceError = error; self.store?.report(error); self.reason = error.localizedDescription
                    done(.failure(error))
                }
            }
        }
        pipeline.onError = { [weak self] error in
            Task { @MainActor in await self?.interrupt(error.localizedDescription) }
        }
        pipeline.onLevel = { [weak self] value in
            Task { @MainActor in
                guard let self, [.preflight, .ready, .countdown, .recording].contains(self.state) else { return }
                self.level = value
            }
        }
        let monitor = playback.liveMonitor
        pipeline.onMonitorSample = { sample in monitor.consume(sample) }
        pipeline.onMonitorFormat = { [weak self] format in
            Task { @MainActor in
                guard let self else { return }
                self.monitoringFormat = format
                self.disableMonitoring()
                self.monitoringConfigured = false
                if !self.playback.engine.isRunning {
                    do { try self.playback.configureMonitoring(format: format); self.monitoringConfigured = true }
                    catch { self.monitoringExplanation = error.localizedDescription }
                }
                self.refreshMonitoringAvailability()
            }
        }
        monitor.onFailure = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                self.disableMonitoring(); self.monitoringAvailable = false; self.monitoringExplanation = message
            }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            monitor.setEnabled(false)
            Task { @MainActor in
                guard let self else { return }
                self.disableMonitoring()
                let fingerprint = self.currentFingerprint()
                guard fingerprint != self.routeFingerprint else { return }
                self.routeConfirmed = false
                // Immediately silence the playback node before awaiting file finalization.
                self.playback.stop(keepPosition: true)
                self.readRoute()
                if self.isCapturing { await self.interrupt("音频路由发生变化。请确认实际输入与伴奏输出后继续。") }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if type == AVAudioSession.InterruptionType.began.rawValue {
                monitor.setEnabled(false)
                Task { @MainActor in await self?.interrupt("系统音频中断，已保护完成片段。") }
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            monitor.setEnabled(false)
            Task { @MainActor in if self?.isBusy == true { await self?.interrupt("应用进入后台，录制已暂停。返回后请确认路由。") } }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            monitor.setEnabled(false)
            Task { @MainActor in await self?.interrupt("系统媒体服务已重置，请结束并重新检查录制。") }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: playback.engine, queue: .main) { [weak self] _ in
            monitor.setEnabled(false)
            Task { @MainActor in
                guard let self else { return }
                self.disableMonitoring()
                guard self.isCapturing else { return }
                await self.interrupt("音频引擎配置发生变化，请检查实际路由后继续。")
            }
        })
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            observers.append(center.addObserver(forName: name, object: pipeline.session, queue: .main) { [weak self] _ in
                monitor.setEnabled(false)
                Task { @MainActor in
                    guard let self, self.isCapturing else { return }
                    await self.interrupt("采集会话被系统中断，已完成片段正在保存。请结束并重新检查设备。")
                }
            })
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver); monitor?.invalidate() }
    private func transition(_ next: RecordingState) throws {
        guard state.canTransition(to: next) else { throw StudioError("当前录制状态不允许执行此操作。") }
        state = next
    }
    func preflight(practice: Bool = false, recovering: UUID? = nil) async {
        guard !isCapturing, state != .finalizing, let store, let project = store.selected, !project.archived else { return }
        do {
            let previous = recovering.flatMap { id in project.takes.first { $0.id == id } }
            if recovering != nil && previous == nil { throw StudioError("待恢复 Take 不在当前工程，原素材未修改。") }
            try transition(.preflight); self.practice = previous?.isPractice ?? practice
            if let previous { video = previous.kind == .video }
            observedBytesPerSecond = video && !self.practice ? 1_500_000 : 40_000
            disableMonitoring(); monitoringConfigured = false; monitoringFormat = nil
            savedTakeID = nil; reason = nil; warning = nil; level = nil; persistenceError = nil; takeID = previous?.id; projectID = project.id
            playback.suspendEngine(); playback.loop = nil
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw StudioError("麦克风权限被拒绝。请在系统设置允许麦克风。") }
            if video && !self.practice {
                guard await AVCaptureDevice.requestAccess(for: .video) else {
                    video = false; throw StudioError("摄像头权限未允许。已切换纯音频，请重新检查后继续，或前往系统设置。")
                }
            }
            let audioSession = AVAudioSession.sharedInstance()
            var options: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP]
            #if compiler(>=6.2)
            if #available(iOS 26, *) { options.insert(.bluetoothHighQualityRecording) }
            #endif
            try audioSession.setCategory(.playAndRecord, mode: .default, options: options)
            try audioSession.setPreferredSampleRate(48000)
            try audioSession.setActive(true)
            try audioSession.setPrefersNoInterruptionsFromSystemAlerts(true)
            inputs = audioSession.availableInputs ?? []
            if let preferred = inputs.first(where: { $0.uid == selectedInputUID }) ?? inputs.first(where: { $0.portType == .bluetoothHFP }) {
                try audioSession.setPreferredInput(preferred)
            }
            try await pipeline.configure(video: video && !self.practice, front: project.frontCamera, landscape: project.landscapeRecording)
            readRoute(); routeConfirmed = false
            availableBytes = try FileIntegrity.available(repository.directory(project.id))
            let budget = DiskBudget(bytesPerSecond: observedBytesPerSecond)
            guard !budget.shouldStop(available: availableBytes) else { throw StudioError("空间已到危险阈值，无法开始录制。请先备份或处理空间。") }
            guard ProcessInfo.processInfo.thermalState != .critical else { throw StudioError("设备温度过高，请冷却后录制。") }
            try store.preparePlayback(for: previous)
            if let monitoringFormat {
                do { try playback.configureMonitoring(format: monitoringFormat); monitoringConfigured = true }
                catch { monitoringConfigured = false; monitoringExplanation = error.localizedDescription }
            }
            resumePosition = previous.map { max(0, $0.end - 3) } ?? playback.position
            try transition(.ready)
            refreshMonitoringAvailability()
            UIDevice.current.isBatteryMonitoringEnabled = true
        } catch {
            disableMonitoring(); monitoringAvailable = false
            await pipeline.shutDown()
            state = .recoverableError; reason = error.localizedDescription; store.report(error)
        }
    }
    func changeInput() async {
        guard state == .ready || state == .interrupted else { return }
        disableMonitoring()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setPreferredInput(inputs.first { $0.uid == selectedInputUID })
            readRoute(); routeConfirmed = false
        } catch { store?.report(error) }
    }
    func readRoute() {
        let session = AVAudioSession.sharedInstance()
        route = "输入：" + session.currentRoute.inputs.map(\.portName).joined(separator: "、")
            + "\n输出：" + session.currentRoute.outputs.map(\.portName).joined(separator: "、")
        routeFingerprint = currentFingerprint()
        highQuality = "常规录音路径；高质量蓝牙未启用。可选择设备麦克风。"
        #if compiler(>=6.2)
        if #available(iOS 26, *), let capability = session.currentRoute.inputs.first?.bluetoothMicrophoneExtension?.highQualityRecording {
            highQuality = capability.isSupported && capability.isEnabled ? "系统报告高质量蓝牙已启用，音质仍待实机确认。" : "当前蓝牙路径未启用高质量录音，可用普通模式或设备麦克风。"
        }
        #endif
        refreshMonitoringAvailability()
    }
    private func refreshMonitoringAvailability() {
        let session = AVAudioSession.sharedInstance(), route = session.currentRoute
        let bluetooth = (route.inputs + route.outputs).contains { [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE].contains($0.portType) }
        let headphones = !route.outputs.isEmpty && route.outputs.allSatisfy { $0.portType == .headphones }
        let latency = session.inputLatency + session.outputLatency + 2 * session.ioBufferDuration
        monitoringAvailable = !bluetooth && headphones && latency.isFinite && latency > 0 && latency < 0.08
            && monitoringConfigured && [.ready, .countdown, .recording].contains(state)
        if bluetooth { monitoringExplanation = "蓝牙路径（含高质量 AirPods）可能产生明显耳返延迟，本版关闭实时耳返；伴奏正常播放。" }
        else if !headphones { monitoringExplanation = "仅在系统明确报告有线耳机输出时开放耳返。USB 不能确认终端为耳机，本版关闭耳返，避免扬声器反馈。" }
        else if latency >= 0.08 || !latency.isFinite || latency <= 0 { monitoringExplanation = "系统报告的音频延迟较高或未知，实时耳返已关闭。" }
        else if !monitoringConfigured { monitoringExplanation = "尚无可用 PCM 耳返格式，请重新检查设备。" }
        else { monitoringExplanation = "可手动开启有线耳返；默认关闭。系统延迟门槛不等于实际听感验证，出现拖音请关闭。" }
        if !monitoringAvailable { disableMonitoring() }
    }
    func setMonitoringEnabled(_ enabled: Bool) {
        if !enabled { disableMonitoring(); return }
        refreshMonitoringAvailability()
        guard monitoringAvailable else { return }
        do { try playback.setMonitoring(true); monitoringEnabled = true }
        catch { disableMonitoring(); monitoringExplanation = error.localizedDescription; monitoringAvailable = false }
    }
    private func disableMonitoring() {
        try? playback.setMonitoring(false)
        monitoringEnabled = false
    }
    private func currentFingerprint() -> String {
        let session = AVAudioSession.sharedInstance(), route = session.currentRoute
        return (route.inputs + route.outputs).map { $0.uid + $0.portType.rawValue }.joined(separator: "|")
            + "|\(session.sampleRate)|\(session.inputNumberOfChannels)|\(session.outputNumberOfChannels)"
    }
    func start() {
        guard (state == .ready || state == .interrupted), routeConfirmed else { store?.error = "请先确认实际收音与伴奏输出。"; return }
        guard persistenceError == nil else { store?.error = "片段登记失败，请先结束当前录制并保留恢复文件。"; return }
        countdownTask = Task {
            do {
                try transition(.countdown)
                for value in (1...3).reversed() { countdown = value; try await Task.sleep(nanoseconds: 1_000_000_000) }
                try Task.checkCancellation(); countdown = nil
                guard currentFingerprint() == routeFingerprint, let store, let project = store.selected, let arrangement = project.arrangement,
                      project.id == projectID else { throw StudioError("录制准备已变化，请重新检查。") }
                if takeID == nil {
                    let take = Take(name: (practice ? "练习 " : "Take ") + String(project.takes.count + 1),
                                    kind: video && !practice ? .video : .audio, arrangementID: arrangement.id,
                                    semitones: arrangement.semitones, isPractice: practice)
                    takeID = take.id
                    store.update { $0.takes.append(take); if !practice { $0.edit.selectedTakeID = take.id } }
                    try await store.flush()
                    try FileIntegrity.encoder().encode(take).write(to: repository.directory(project.id).appendingPathComponent("recording.json"), options: .atomic)
                }
                guard resumePosition.isFinite, resumePosition >= 0, resumePosition < playback.duration else {
                    throw StudioError("接唱位置必须在伴奏时长内，请调整秒数后重试。")
                }
                // Warm the playback graph before selecting the common host anchor;
                // cold audio-engine startup must not consume the scheduled lead-in.
                try playback.prepare()
                let host = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.25)
                let session = AVAudioSession.sharedInstance()
                let savedSegments = store.selected?.takes.first(where: { $0.id == takeID })?.segments ?? []
                let sequenceStart = (savedSegments.enumerated().map { $0.element.sequence ?? $0.offset }.max() ?? -1) + 1
                try await pipeline.begin(directory: repository.directory(project.id), songStart: resumePosition, host: host,
                       route: route, inputLatency: session.inputLatency, outputLatency: session.outputLatency, sequenceStart: sequenceStart)
                try playback.play(from: resumePosition, hostTime: host)
                try transition(.recording); refreshMonitoringAvailability(); UIApplication.shared.isIdleTimerDisabled = true
                startMonitor()
            } catch is CancellationError { countdown = nil }
            catch { countdown = nil; await interrupt(error.localizedDescription); store?.report(error) }
        }
    }
    func cancelCountdown() {
        guard state == .countdown else { return }
        countdownTask?.cancel(); countdown = nil; state = takeID == nil ? .ready : .interrupted
    }
    func interrupt(_ message: String) async {
        guard isBusy, state != .finalizing, !stopping else { return }
        stopping = true; countdownTask?.cancel(); countdown = nil
        disableMonitoring(); monitoringAvailable = false
        resumePosition = max(0, playback.position - 3); playback.suspendEngine()
        monitor?.invalidate(); routeConfirmed = false; reason = message
        do { try await pipeline.end() } catch { store?.report(error) }
        state = .interrupted; level = nil; stopping = false; UIApplication.shared.isIdleTimerDisabled = false
    }
    func finish() async {
        guard isBusy, !stopping else { return }
        stopping = true; countdownTask?.cancel(); countdown = nil
        disableMonitoring(); monitoringAvailable = false
        playback.suspendEngine(); monitor?.invalidate(); state = .finalizing
        do {
            try await pipeline.end()
            if let persistenceError { throw persistenceError }
            guard let takeID, let store, let take = store.selected?.takes.first(where: { $0.id == takeID }), !take.segments.isEmpty else {
                throw StudioError("尚无已保存的录制片段，未标记为保存成功。")
            }
            try await store.flush()
            if let projectID {
                let journal = repository.directory(projectID).appendingPathComponent("recording.json")
                if FileManager.default.fileExists(atPath: journal.path) { try FileManager.default.removeItem(at: journal) }
            }
            state = .saved; savedTakeID = takeID
        } catch { state = .recoverableError; reason = error.localizedDescription; store?.report(error) }
        await pipeline.shutDown(); level = nil; stopping = false; UIApplication.shared.isIdleTimerDisabled = false
    }
    private func commit(_ chunk: CapturedChunk) async throws {
        guard let projectID, let takeID, let store, store.selectedID == projectID,
              store.selected?.takes.contains(where: { $0.id == takeID }) == true else { throw StudioError("片段目标工程缺失，原文件已保留。") }
        let vocal = try await repository.registerFile(chunk.vocalURL, projectID: projectID, role: .vocal,
                      duration: .init(value: chunk.duration.value, timescale: chunk.duration.timescale), sampleRate: chunk.sampleRate, channels: chunk.channels)
        var video: MediaAsset?
        if let url = chunk.videoURL {
            video = try await repository.registerFile(url, projectID: projectID, role: .video,
                       duration: .init(value: chunk.duration.value, timescale: chunk.duration.timescale))
        }
        func time(_ value: CMTime?) -> MediaTime? { value.map { .init(value: $0.value, timescale: $0.timescale) } }
        var segment = RecordingSegment(vocalAssetID: vocal.id, videoAssetID: video?.id, songStart: .init(seconds: chunk.songStart),
                         hostStart: time(chunk.anchor)!, duration: time(chunk.duration)!, audioFirstPTS: time(chunk.audioPTS),
                         videoFirstPTS: time(chunk.videoPTS), playbackHostTime: chunk.playbackHost,
                         inputLatency: chunk.inputLatency, outputLatency: chunk.outputLatency, route: chunk.route)
        segment.sequence = chunk.sequence
        store.update { project in
            project.assets.append(vocal); if let video { project.assets.append(video) }
            if let index = project.takes.firstIndex(where: { $0.id == takeID }) {
                project.takes[index].segments.append(segment)
                // A reboot resets host clock values; only take-local sequence defines append order.
                project.takes[index].segments = Timeline.orderedSegments(project.takes[index].segments)
            }
        }
        try await store.flush()
        let seconds = CMTimeGetSeconds(chunk.duration)
        if seconds.isFinite && seconds > 0 {
            let observed = (Double(vocal.bytes) + Double(video?.bytes ?? 0)) / seconds * 1.5
            if observed.isFinite { observedBytesPerSecond = max(observedBytesPerSecond, observed) }
        }
    }
    private func startMonitor() {
        monitor?.invalidate()
        monitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let projectID = self.projectID, self.state == .recording else { return }
                do {
                    self.refreshMonitoringAvailability()
                    self.availableBytes = try FileIntegrity.available(self.repository.directory(projectID))
                    let budget = DiskBudget(bytesPerSecond: self.observedBytesPerSecond)
                    if budget.shouldStop(available: self.availableBytes) || ProcessInfo.processInfo.thermalState == .critical {
                        self.reason = "空间或温度达到危险阈值，录制已保护性结束，未删除源素材。"; await self.finish()
                    } else if self.availableBytes < budget.warningBytes { self.warning = "剩余空间较低，请尽快结束并备份。" }
                    if UIDevice.current.batteryLevel >= 0 && UIDevice.current.batteryLevel < 0.1 { self.warning = "电量低于 10%，建议连接电源。" }
                    if self.playback.position >= self.playback.duration { await self.finish() }
                } catch { await self.interrupt("无法检查剩余空间，请先结束录制。") }
            }
        }
    }
}

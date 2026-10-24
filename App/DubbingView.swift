import SwiftUI
import AVFoundation
import CoverCore

@MainActor final class DubbingRecorder: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "studio.dubbing")
    @Published var ready = false
    @Published var recording = false
    @Published var finishedURL: URL?
    @Published var error: String?
    @Published private(set) var routeRevision = 0
    private var preparedRoute = ""
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    override init() {
        super.init()
        for name in [AVAudioSession.routeChangeNotification, AVAudioSession.interruptionNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if name == AVAudioSession.routeChangeNotification && self.fingerprint() == self.preparedRoute { return }
                    self.routeRevision += 1; self.ready = false
                    if self.recording { self.error = "补拍因路由或系统状态变化而停止，已保留画面文件。"; self.stop() }
                }
            })
        }
    }
    deinit { timer?.invalidate(); observers.forEach(NotificationCenter.default.removeObserver) }
    func prepare(front: Bool, landscape: Bool) async throws {
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw StudioError("未获得摄像头权限。可从相册或文件导入补拍画面。") }
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    if self.session.isRunning { self.session.stopRunning() }
                    self.session.beginConfiguration(); self.session.automaticallyConfiguresApplicationAudioSession = false
                    self.session.sessionPreset = .hd1920x1080
                    self.session.inputs.forEach { self.session.removeInput($0) }; self.session.outputs.forEach { self.session.removeOutput($0) }
                    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back) else { throw StudioError("摄像头不可用。") }
                    let input = try AVCaptureDeviceInput(device: camera)
                    guard self.session.canAddInput(input), self.session.canAddOutput(self.output) else { throw StudioError("补拍视频会话不可用。") }
                    self.session.addInput(input); self.session.addOutput(self.output)
                    self.output.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
                    if let connection = self.output.connection(with: .video) {
                        if connection.isVideoRotationAngleSupported(landscape ? 0 : 90) { connection.videoRotationAngle = landscape ? 0 : 90 }
                        if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false }
                    }
                    self.session.commitConfiguration(); self.session.startRunning(); continuation.resume()
                } catch { self.session.commitConfiguration(); continuation.resume(throwing: error) }
            }
        }
        preparedRoute = fingerprint(); ready = true
    }
    func start(to url: URL) throws {
        guard ready, !recording, fingerprint() == preparedRoute else { throw StudioError("补拍设备或输出已变化，请重新检查后确认耳机。") }
        let budget = DiskBudget(bytesPerSecond: 1_500_000)
        guard try !budget.shouldStop(available: FileIntegrity.available(url.deletingLastPathComponent())) else { throw StudioError("补拍空间不足。") }
        finishedURL = nil; recording = true; output.startRecording(to: url, recordingDelegate: self)
        UIApplication.shared.isIdleTimerDisabled = true
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                do {
                    if try budget.shouldStop(available: FileIntegrity.available(url.deletingLastPathComponent())) || ProcessInfo.processInfo.thermalState == .critical {
                        self?.error = "空间或温度达到保护阈值，补拍已结束。"; self?.stop()
                    }
                } catch { self?.error = error.localizedDescription; self?.stop() }
            }
        }
    }
    func stop() {
        timer?.invalidate(); onStop?()
        if output.isRecording { output.stopRecording() }
        UIApplication.shared.isIdleTimerDisabled = false
    }
    private func fingerprint() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute
        return (route.inputs + route.outputs).map { $0.uid + $0.portType.rawValue }.joined(separator: "|")
    }
    func shutDown() {
        stop(); queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        Task { @MainActor in onStart?() }
    }
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo fileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in
            recording = false; timer?.invalidate(); onStop?(); UIApplication.shared.isIdleTimerDisabled = false
            let finalized = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? (error == nil)
            if finalized { finishedURL = fileURL } else { self.error = "补拍未完成封装。文件仍保留：" + (error?.localizedDescription ?? "未知错误") }
        }
    }
}

struct DubbingView: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) var dismiss
    @StateObject private var recorder = DubbingRecorder()
    @State private var referenceMix = true
    @State private var routeConfirmed = false
    @State private var player: AVPlayer?
    @State private var preparing = false
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?
    @State private var route = ""
    @State private var committed = false
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if recorder.ready {
                    CameraPreview(session: recorder.session, mirrored: store.selected?.mirrorPreview ?? true).aspectRatio(9.0/16, contentMode: .fit).frame(maxHeight: 450)
                }
                Text("只保存补拍画面，已确认人声保持原样。").foregroundStyle(.secondary)
                Picker("耳机参考", selection: $referenceMix) { Text("人声 + 伴奏成品").tag(true); Text("只有伴奏").tag(false) }.pickerStyle(.segmented).disabled(recorder.ready)
                if !recorder.ready {
                    Button("准备补拍") { Task { await prepare() } }.buttonStyle(.borderedProminent).disabled(preparing)
                } else if recorder.recording {
                    Button("结束补拍") { recorder.stop() }.buttonStyle(.borderedProminent).tint(.red)
                } else if recorder.finishedURL == nil {
                    Text(route).font(.footnote)
                    Toggle("已确认耳机输出", isOn: $routeConfirmed)
                    if let countdown { Text("\(countdown)").font(.largeTitle) }
                    Button("倒数 3 秒后补拍") { begin() }.buttonStyle(.borderedProminent).disabled(!routeConfirmed || countdown != nil)
                }
                if preparing { ProgressView("正在准备参考音频与摄像头…") }
                if let error = recorder.error { Text(error).foregroundStyle(.orange) }
                if committed { Label("补拍画面已保存并用于当前后期", systemImage: "checkmark.circle") }
                Text("补拍起点可能需要人工校准。请先预览画面，再导出；原始音轨不会替换。").font(.footnote).foregroundStyle(.secondary)
            }.padding().frame(maxWidth: 700).frame(maxWidth: .infinity)
        }.navigationTitle("补拍画面").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(recorder.recording || preparing || countdown != nil) } }
            .interactiveDismissDisabled(recorder.recording || countdown != nil || preparing)
            .onAppear { store.auxiliaryRecording = true }
            .onChange(of: recorder.routeRevision) { _, _ in routeConfirmed = false; countdownTask?.cancel(); countdown = nil }
            .onChange(of: recorder.finishedURL) { _, url in
                guard let url else { return }
                Task {
                    do {
                        guard let project = store.selected else { return }
                        let duration = try await AVURLAsset(url: url).load(.duration)
                        guard duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 else { throw StudioError("补拍视频时长无效，文件保留但未加入编辑。") }
                        let asset = try await store.repository.registerFile(url, projectID: project.id, role: .video,
                                     duration: .init(value: duration.value, timescale: duration.timescale))
                        guard store.selectedID == project.id else { throw StudioError("补拍目标工程已切换，素材留在原工程，未修改其他工程。") }
                        store.update { $0.assets.append(asset); $0.edit.visualAssetID = asset.id; $0.edit.visualSongStart = $0.edit.trimStart; $0.edit.visualOffset = 0 }; try await store.flush(); committed = true
                    } catch { store.report(error) }
                }
            }
            .onDisappear { countdownTask?.cancel(); player?.pause(); store.playback.stop(keepPosition: true); recorder.shutDown(); store.auxiliaryRecording = false }
    }
    func prepare() async {
        guard let project = store.selected, let take = project.selectedTake else { return }
        preparing = true; defer { preparing = false }
        do {
            store.playback.suspendEngine()
            if referenceMix {
                let url = try await store.exports.previewMix(project: project, root: store.repository.directory(project.id)); player = AVPlayer(url: url)
            } else { try store.preparePlayback(for: take) }
            try await recorder.prepare(front: project.frontCamera, landscape: project.landscapeRecording)
            route = "输出：" + AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName).joined(separator: "、")
            recorder.onStart = {
                if referenceMix { player?.play() }
                else {
                    do { try store.playback.play(from: project.edit.trimStart) } catch { store.report(error); recorder.stop() }
                }
            }
            recorder.onStop = { player?.pause(); store.playback.stop(keepPosition: true) }
        } catch { store.report(error) }
    }
    func begin() {
        countdownTask = Task {
            do {
                for value in (1...3).reversed() { countdown = value; try await Task.sleep(nanoseconds: 1_000_000_000) }
                countdown = nil
                guard let project = store.selected else { return }
                let url = store.repository.directory(project.id).appendingPathComponent("media/\(UUID().uuidString)-dubbing.mov")
                try recorder.start(to: url)
            } catch { countdown = nil; store.report(error) }
        }
    }
}

import SwiftUI
import AVKit
import CoverCore

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let mirrored: Bool
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView(); view.preview.session = session; view.preview.videoGravity = .resizeAspectFill; return view
    }
    func updateUIView(_ view: PreviewView, context: Context) {
        if let connection = view.preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = mirrored
        }
    }
}

struct RecordView: View {
    @EnvironmentObject var store: StudioStore
    var body: some View {
        if let project = store.selected, !project.archived { RecordPanel(store: store, recording: store.recording, playback: store.playback) }
        else { EmptyProjectView(archived: store.selected?.archived == true) }
    }
}

struct RecordPanel: View {
    @ObservedObject var store: StudioStore
    @ObservedObject var recording: RecordingCoordinator
    @ObservedObject var playback: PlaybackEngine
    @State private var preview = false
    var locked: Bool { recording.controlsLocked }
    var project: StudioProject? { store.selected }
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if recording.video && recording.isBusy {
                    CameraPreview(session: recording.pipeline.session, mirrored: project?.mirrorPreview ?? true)
                        .aspectRatio(project?.landscapeRecording == true ? 16.0/9 : 9.0/16, contentMode: .fit)
                        .frame(maxHeight: 480).clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(alignment: .topLeading) {
                            if recording.state == .recording { Label("录制中", systemImage: "record.circle.fill").foregroundStyle(.white).padding(8).background(.red, in: Capsule()).padding() }
                        }
                } else {
                    Image(systemName: recording.video ? "video" : "mic").font(.largeTitle).foregroundStyle(.secondary).frame(height: 100)
                }
                if project?.showLyrics == true { LyricsDisplay(lyrics: recording.currentLyrics, position: playback.position).padding(.horizontal).allowsHitTesting(!locked) }
                if let countdown = recording.countdown { Text("\(countdown)").font(.largeTitle.bold()).monospacedDigit().accessibilityLabel("倒计时 \(countdown)") }
                if let reason = recording.reason { Text(reason).font(.callout).foregroundStyle(.orange) }
                if let warning = recording.warning { Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if recording.state == .countdown {
                    Button("取消倒计时", role: .cancel) { recording.cancelCountdown() }.buttonStyle(.bordered)
                } else if recording.state == .finalizing {
                    ProgressView("正在保存原始片段…")
                } else if recording.state == .ready || recording.state == .interrupted {
                    routeControls
                    if recording.state == .interrupted {
                        Text("恢复将生成新片段，保留旧片段。默认回退 3 秒，可在后期调整接唱切点。").font(.footnote).foregroundStyle(.secondary)
                        HStack { Text("接唱秒数"); TextField("秒", value: $recording.resumePosition, format: .number).keyboardType(.decimalPad) }
                        Button("重新检查摄像头与音频会话") { Task { await recording.recheckInterruptedSession() } }
                    }
                    Button("倒数 3 秒后开始") { recording.start() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!recording.routeConfirmed)
                    Button("结束并保留已有片段") { Task { await recording.finish() } }
                    Button(recording.state == .ready ? "取消本次准备" : "稍后继续（保留待恢复）") { Task { await recording.leavePreparedSession() } }
                } else if recording.state != .recording {
                    config
                    Button { Task { await recording.preflight() } } label: { Label("检查设备与路由", systemImage: "checkmark.shield") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    if recording.savedTakeID != nil { Button("预览刚保存的 Take") { preview = true }.buttonStyle(.bordered) }
                }
            }.padding().frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
        .scrollDisabled(locked)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if recording.state == .recording { captureControls }
        }
        .onChange(of: recording.savedTakeID) { _, id in if id != nil { preview = true } }
        .onChange(of: recording.video) { _, value in if project?.recordVideo != value { store.update { $0.recordVideo = value } } }
        .sheet(isPresented: $preview) { NavigationStack { TakePreviewView(takeID: recording.savedTakeID) } }
    }
    private var captureControls: some View {
        VStack(spacing: 10) {
            HStack {
                Text(clock(playback.position)).font(.title2.monospacedDigit())
                Spacer()
                if let level = recording.level { ProgressView(value: Double(level)).tint(.green).frame(maxWidth: 180).accessibilityLabel("人声电平") }
                else { Text("电平暂不可用").font(.caption).foregroundStyle(.secondary) }
            }
            Toggle("锁定控制", isOn: Binding(get: { recording.controlsLocked }, set: { recording.setControlsLocked($0) }))
            Text(locked ? "已锁定页面切换、设置和滚动。可随时解锁或长按停止。" : "长按 1 秒停止；锁定后仍可紧急停止。").font(.footnote).foregroundStyle(.secondary)
            Text("长按停止并保存").font(.headline).foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 54)
                .background(.red, in: Capsule()).contentShape(Capsule())
                .onLongPressGesture(minimumDuration: 1) { Task { await recording.finish() } }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { Task { await recording.finish() } }
        }.padding().frame(maxWidth: 760).frame(maxWidth: .infinity).background(.regularMaterial)
    }
    var routeControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(recording.route).font(.subheadline)
            Text(recording.highQuality).font(.footnote).foregroundStyle(.secondary)
            Text("人声耳返默认关闭，伴奏继续播放。蓝牙路径音质与同步需实机检查。").font(.footnote).foregroundStyle(.secondary)
            Toggle("实时人声耳返", isOn: Binding(get: { recording.monitoringEnabled }, set: { recording.setMonitoringEnabled($0) })).disabled(!recording.monitoringAvailable)
            Text(recording.monitoringExplanation).font(.footnote).foregroundStyle(.secondary)
            Picker("麦克风", selection: $recording.selectedInputUID) {
                Text("系统选择").tag("")
                ForEach(recording.inputs, id: \.uid) { input in Text(input.portName).tag(input.uid) }
            }.onChange(of: recording.selectedInputUID) { _, _ in Task { await recording.changeInput() } }
            Text("可用空间：" + ByteCountFormatter.string(fromByteCount: recording.availableBytes, countStyle: .file)).font(.footnote)
            Toggle("已确认实际输入与伴奏输出", isOn: $recording.routeConfirmed)
        }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
    var config: some View {
        VStack(spacing: 16) {
            Toggle("录制视频", isOn: $recording.video)
            if recording.video {
                Picker("镜头", selection: store.binding(\.frontCamera, fallback: true)) {
                    Text("前置").tag(true); Text("后置").tag(false)
                }.pickerStyle(.segmented)
                Toggle("横屏构图", isOn: store.binding(\.landscapeRecording, fallback: false))
                Toggle("镜像预览", isOn: store.binding(\.mirrorPreview, fallback: true))
                Text("镜头、方向与比例在录制期间锁定；导出镜像在后期独立设置。").font(.footnote).foregroundStyle(.secondary)
            }
            Toggle("显示歌词", isOn: store.binding(\.showLyrics, fallback: true))
            Button("打开系统权限设置") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
        }
    }
}

struct TakePreviewView: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) var dismiss
    let takeID: UUID?
    @State private var player: AVPlayer?
    @State private var video: AVMutableVideoComposition?
    var body: some View {
        VStack(spacing: 20) {
            if let player { VideoPlayer(player: player).frame(minHeight: 250) }
            else { ProgressView("正在读取原始片段…") }
            Text("原始画面与干声预览。伴奏、效果和字幕在后期试听 / 导出时合成。").font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            if let project = store.selected, let take = project.takes.first(where: { $0.id == takeID }) {
                Text("\(take.name) · \(take.segments.count) 个已保存片段").font(.headline)
                Button(take.favorite ? "取消满意标记" : "标记满意") {
                    store.update { if let index = $0.takes.firstIndex(where: { $0.id == takeID }) { $0.takes[index].favorite.toggle() } }
                }
                Button(take.isPractice ? "转为正式 Audio Take" : "选作后期 Take") {
                    Task {
                        do {
                            if take.isPractice { try await store.promote(take.id) }
                            else { store.update { $0.edit.selectedTakeID = take.id }; try await store.flush() }
                            dismiss()
                        } catch { store.report(error) }
                    }
                }.buttonStyle(.borderedProminent)
            }
            Spacer()
        }.navigationTitle("Take 预览").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task {
                guard var project = store.selected else { return }
                project.edit.selectedTakeID = takeID; project.edit = EditGraph(); project.edit.selectedTakeID = takeID
                do {
                    let (composition, video) = try await VideoComposer.composition(project: project, root: store.repository.directory(project.id), mix: nil, raw: true)
                    let item = AVPlayerItem(asset: composition); item.videoComposition = video; player = AVPlayer(playerItem: item)
                } catch { store.report(error) }
            }.onDisappear { player?.pause() }
    }
}

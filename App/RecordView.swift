import SwiftUI
import AVKit
import CoverCore

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let mirrored: Bool
    var landscape = false
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView(); view.preview.session = session; view.preview.videoGravity = .resizeAspect; return view
    }
    func updateUIView(_ view: PreviewView, context: Context) {
        if let connection = view.preview.connection, connection.isVideoRotationAngleSupported(landscape ? 0 : 90) {
            connection.videoRotationAngle = landscape ? 0 : 90
        }
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
    @State private var lyrics = false
    @State private var rerecordRequested = false
    @State private var sectionRecording = false
    @State private var sectionStart: Double = 0
    var locked: Bool { recording.controlsLocked }
    var project: StudioProject? { store.selected }
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 850 && geometry.size.width > geometry.size.height
            VStack(alignment: .leading, spacing: 16) {
                songHeader
                if wide {
                    HStack(alignment: .top, spacing: 24) {
                        camera(maximumHeight: geometry.size.height - 110)
                            .frame(width: geometry.size.width * 0.48)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                lyricsPanel(maximumHeight: max(160, geometry.size.height - 230))
                                settingsPanel
                            }.padding(.bottom, 8)
                        }.scrollDisabled(locked).frame(maxWidth: .infinity)
                    }.accessibilityIdentifier("record-wide-layout")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            camera(maximumHeight: min(360, geometry.size.height * 0.46))
                            lyricsPanel(maximumHeight: 220)
                            settingsPanel
                        }
                    }.scrollDisabled(locked)
                }
            }.padding(.horizontal, wide ? 24 : 16).padding(.top, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { primaryControls }
        .onChange(of: recording.savedTakeID) { _, id in if id != nil { preview = true } }
        .onChange(of: recording.video) { _, value in if project?.recordVideo != value { store.update { $0.recordVideo = value } } }
        .onChange(of: store.selectedID) { _, _ in sectionRecording = false; sectionStart = 0 }
        .sheet(isPresented: $lyrics) { NavigationStack { LyricsEditor(forTake: false) } }
        .sheet(isPresented: $preview, onDismiss: {
            if rerecordRequested { rerecordRequested = false; sectionRecording = false; Task { await recording.preflight() } }
        }) {
            NavigationStack {
                TakePreviewView(takeID: recording.savedTakeID, onRerecord: {
                    rerecordRequested = true; preview = false
                })
            }
        }
        .task(id: project?.arrangementID) {
            guard !recording.isBusy, project?.arrangement?.backingAssetID != nil else { return }
            do { try store.preparePlayback() } catch { store.report(error) }
        }
    }
    private var songHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(project?.song.title ?? "").font(.title2.weight(.semibold)).lineLimit(2)
                Spacer()
                Text(recording.displayTakeName).font(.headline).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                ProgressView(value: playback.duration > 0 ? min(playback.position / playback.duration, 1) : 0)
                    .accessibilityLabel("伴奏进度")
                Text(clock(playback.position) + " / " + clock(playback.duration)).font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary).fixedSize()
            }
        }
    }
    private func camera(maximumHeight: CGFloat) -> some View {
        let ratio = project?.landscapeRecording == true ? 16.0 / 9 : 9.0 / 16
        return Color.black
            .frame(height: max(150, maximumHeight))
            .overlay {
                if recording.video && recording.isBusy {
                    CameraPreview(session: recording.pipeline.session, mirrored: project?.mirrorPreview ?? true, landscape: project?.landscapeRecording ?? false)
                        .aspectRatio(ratio, contentMode: .fit)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: recording.video ? "video" : "mic").font(.largeTitle)
                        Text(recording.video ? "准备录制后显示摄像头" : "纯音频录制").font(.callout)
                    }.foregroundStyle(.white.opacity(0.8))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(alignment: .topLeading) {
                if recording.state == .recording {
                    Label("录制中", systemImage: "record.circle.fill").font(.subheadline.bold())
                        .foregroundStyle(.white).padding(8).background(.red, in: Capsule()).padding(12)
                }
            }
            .overlay {
                if let countdown = recording.countdown {
                    Text("\(countdown)").font(.system(size: 72, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white).shadow(radius: 4).accessibilityLabel("倒计时 \(countdown)")
                }
            }
    }
    private func lyricsPanel(maximumHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("歌词").font(.headline)
                Spacer()
                Button(recording.currentLyrics.lines.isEmpty ? "添加歌词" : "编辑歌词") { lyrics = true }
                    .accessibilityIdentifier("record-lyrics")
                    .buttonStyle(.bordered).disabled(!recording.allowsLyricsEditing || locked)
            }
            if project?.showLyrics == true {
                LyricsDisplay(lyrics: recording.currentLyrics, position: playback.position, maximumHeight: maximumHeight)
                    .id(recording.lyricsScrollID).allowsHitTesting(!locked)
            } else { Text("歌词显示已关闭，可在录制设置中开启。").foregroundStyle(.secondary) }
        }
    }
    @ViewBuilder private var settingsPanel: some View {
        if let reason = recording.reason { Label(reason, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
        if let warning = recording.warning { Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        if !recording.isBusy {
            DisclosureGroup("录制设置") {
                VStack(spacing: 14) {
                    Toggle("录制视频", isOn: $recording.video)
                    if recording.video {
                        Picker("镜头", selection: store.binding(\.frontCamera, fallback: true)) {
                            Text("前置").tag(true); Text("后置").tag(false)
                        }.pickerStyle(.segmented)
                        Toggle("横屏构图", isOn: store.binding(\.landscapeRecording, fallback: false))
                        Toggle("镜像预览", isOn: store.binding(\.mirrorPreview, fallback: true))
                    }
                    Toggle("显示歌词", isOn: store.binding(\.showLyrics, fallback: true))
                    Toggle("从指定片段起点录制", isOn: $sectionRecording)
                    if sectionRecording {
                        HStack { Text("起点（秒）"); TextField("秒", value: $sectionStart, format: .number).keyboardType(.decimalPad) }
                    }
                    Text("完整 Take 默认从 00:00 开始。镜头、方向与比例在录制期间锁定。").font(.footnote).foregroundStyle(.secondary)
                    Button("打开系统权限设置") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                }.padding(.top, 12)
            }
        }
        if recording.state == .ready || recording.state == .interrupted {
            DisclosureGroup("高级音频设置") {
                VStack(alignment: .leading, spacing: 14) {
                    Text(recording.highQuality).font(.footnote).foregroundStyle(.secondary)
                    Toggle("实时人声耳返", isOn: Binding(get: { recording.monitoringEnabled }, set: { recording.setMonitoringEnabled($0) })).disabled(!recording.monitoringAvailable)
                    Text(recording.monitoringExplanation).font(.footnote).foregroundStyle(.secondary)
                    Picker("麦克风", selection: $recording.selectedInputUID) {
                        Text("系统选择").tag("")
                        ForEach(recording.inputs, id: \.uid) { input in Text(input.portName).tag(input.uid) }
                    }.onChange(of: recording.selectedInputUID) { _, _ in Task { await recording.changeInput() } }
                    let session = AVAudioSession.sharedInstance()
                    Text(String(format: "系统报告延迟：输入 %.0f ms · 输出 %.0f ms", session.inputLatency * 1000, session.outputLatency * 1000)).font(.footnote)
                    Text("可用空间：" + ByteCountFormatter.string(fromByteCount: recording.availableBytes, countStyle: .file)).font(.footnote)
                }.padding(.top, 12)
            }
        }
    }
    private var primaryControls: some View {
        VStack(spacing: 10) {
            if recording.state == .recording {
                HStack {
                    if let level = recording.level { ProgressView(value: Double(level)).tint(.green).frame(maxWidth: 180).accessibilityLabel("人声电平") }
                    Spacer()
                    Toggle("锁定控制", isOn: Binding(get: { recording.controlsLocked }, set: { recording.setControlsLocked($0) })).fixedSize()
                }
                Text("长按停止并保存").font(.headline).foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 54)
                    .background(.red, in: Capsule()).contentShape(Capsule())
                    .onLongPressGesture(minimumDuration: 1) { Task { await recording.finish() } }
                    .accessibilityAddTraits(.isButton).accessibilityAction { Task { await recording.finish() } }
                Text(locked ? "已锁定；仍可解锁或长按 1 秒停止。" : "长按 1 秒停止，完成后自动保存 Take。").font(.caption).foregroundStyle(.secondary)
            } else if recording.state == .countdown {
                Button("取消倒计时", role: .cancel) { recording.cancelCountdown() }.buttonStyle(.bordered).controlSize(.large)
            } else if recording.state == .preflight || recording.state == .finalizing {
                ProgressView(recording.state == .preflight ? "正在准备摄像头和收音…" : "正在保存 Take…").padding(12)
            } else if recording.state == .ready || recording.state == .interrupted {
                Text(recording.route).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                Toggle("确认收音和伴奏输出", isOn: $recording.routeConfirmed)
                if recording.state == .interrupted {
                    HStack {
                        Text("接唱起点（秒）")
                        TextField("秒", value: $recording.resumePosition, format: .number).keyboardType(.decimalPad)
                        Button("重新检查") { Task { await recording.recheckInterruptedSession() } }
                    }
                    Text("默认回退 3 秒；已有片段保留。").font(.caption).foregroundStyle(.secondary)
                }
                ViewThatFits(in: .horizontal) {
                    HStack { sessionButtons }
                    VStack { sessionButtons }
                }
            } else {
                Button { Task { await recording.preflight(sectionStart: sectionRecording ? sectionStart : nil) } } label: {
                    Label(recording.savedTakeID == nil ? "准备新 Take" : "重新录制新 Take", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("record-prepare")
                HStack {
                    Text(sectionRecording ? "从 " + clock(sectionStart) + " 开始" : "完整录制 · 从 00:00 开始").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if recording.savedTakeID != nil { Button("预览刚保存的 Take") { preview = true } }
                }
            }
        }.padding().frame(maxWidth: 1100).frame(maxWidth: .infinity).background(.regularMaterial)
    }
    @ViewBuilder private var sessionButtons: some View {
        Button("倒数 3 秒后开始") { recording.start() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!recording.routeConfirmed)
        Button(recording.state == .ready ? "取消准备" : "稍后继续") { Task { await recording.leavePreparedSession() } }.buttonStyle(.bordered)
        if recording.state == .interrupted { Button("结束并保存") { Task { await recording.finish() } } }
    }
}

struct TakePreviewView: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) var dismiss
    let takeID: UUID?
    var onRerecord: (() -> Void)? = nil
    @State private var player: AVPlayer?
    @State private var video: AVMutableVideoComposition?
    var body: some View {
        VStack(spacing: 20) {
            if let player { VideoPlayer(player: player).frame(minHeight: 250) }
            else { ProgressView("正在读取原始片段…") }
            Text("原始画面与干声预览。伴奏、效果和字幕在后期试听 / 导出时合成。").font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            if let project = store.selected, let take = project.takes.first(where: { $0.id == takeID }) {
                Text(project.song.title).font(.title2.weight(.semibold))
                Text(take.name + " · " + clock(take.recordedDuration)).font(.headline)
                Button(take.favorite ? "取消满意标记" : "标记满意") {
                    store.update { if let index = $0.takes.firstIndex(where: { $0.id == takeID }) { $0.takes[index].favorite.toggle() } }
                }
                Button(take.isPractice ? "转为正式 Audio Take" : "进入后期编辑") {
                    Task {
                        do {
                            if take.isPractice { try await store.promote(take.id) }
                            else { store.update { $0.edit.selectedTakeID = take.id }; try await store.flush() }
                            dismiss(); store.workspaceTab = 2
                        } catch { store.report(error) }
                    }
                }.buttonStyle(.borderedProminent)
                if let onRerecord { Button("重新录制新 Take", action: onRerecord).buttonStyle(.bordered) }
                DisclosureGroup("录制详情") {
                    Text("\(take.segments.count) 个已保存片段 · 录制变调 \(take.semitones) 半音").font(.footnote).foregroundStyle(.secondary)
                }.padding(.horizontal)
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

import SwiftUI
import AVKit
import CoverCore

struct PracticeView: View {
    @EnvironmentObject var store: StudioStore
    var body: some View {
        if let project = store.selected, !project.archived {
            PracticePanel(store: store, playback: store.playback, recording: store.recording)
        } else { EmptyProjectView(archived: store.selected?.archived == true) }
    }
}

struct PracticePanel: View {
    @ObservedObject var store: StudioStore
    @ObservedObject var playback: PlaybackEngine
    @ObservedObject var recording: RecordingCoordinator
    @State private var lyrics = false
    @State private var looping = false
    @State private var preview: AVPlayer?
    @State private var showPreview = false
    var project: StudioProject? { store.selected }
    var body: some View {
        List {
            Section {
                Text(project?.song.title ?? "").font(.title2.weight(.semibold))
                if let artist = project?.song.artist, !artist.isEmpty { Text(artist).foregroundStyle(.secondary) }
                if let name = project?.arrangement?.name { Text(name).font(.subheadline).foregroundStyle(.secondary) }
                if project?.arrangement?.backingAssetID == nil { Text("当前是待分离原曲。请导入准备好的伴奏版本。").foregroundStyle(.orange) }
            }
            Section("伴奏") {
                HStack {
                    Button {
                        do {
                            if playback.playing { playback.stop(keepPosition: true) }
                            else { try playback.activatePlaybackSession(); try store.preparePlayback(); try playback.play() }
                        } catch { store.report(error) }
                    } label: { Label(playback.playing ? "暂停" : "播放", systemImage: playback.playing ? "pause.fill" : "play.fill") }
                    .buttonStyle(.borderedProminent).disabled(recording.isBusy)
                    Spacer()
                    Text(clock(playback.position) + " / " + clock(playback.duration)).monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { playback.position }, set: { value in do { try playback.seek(value) } catch { store.report(error) } }), in: 0...max(1, playback.duration))
                    .accessibilityLabel("伴奏位置").disabled(recording.isBusy)
                Stepper(value: store.arrangementBinding(\.semitones, fallback: 0), in: -12...12) {
                    LabeledContent("升降调", value: String(format: "%+d 半音", project?.arrangement?.semitones ?? 0))
                }.disabled(recording.isBusy)
                Text("速度保持 100%。较大幅度变调可能影响音色，请试听。").font(.footnote).foregroundStyle(.secondary)
                HStack { Image(systemName: "speaker.wave.2"); Slider(value: $playback.gain, in: 0...1).accessibilityLabel("伴奏音量") }
            }
            Section("区间练习") {
                HStack {
                    Button("标记 A：" + clock(project?.loopStart ?? 0)) { store.update { $0.loopStart = playback.position }; updateLoop() }
                    Spacer()
                    Button("标记 B：" + clock(project?.loopEnd ?? 0)) { store.update { $0.loopEnd = playback.position }; updateLoop() }
                }.disabled(recording.isBusy)
                Toggle("A–B 循环试听", isOn: $looping).disabled(recording.isBusy)
                    .onChange(of: looping) { _, _ in updateLoop() }
                Text("练习录音按完整时间线保存；开始录音时关闭循环，避免覆盖时间轴。录完可重新打开循环试听。").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                LyricsDisplay(lyrics: project?.arrangement?.lyrics ?? Lyrics(), position: playback.position)
                Button("编辑歌词 / 标记时间点") { lyrics = true }.disabled(recording.isBusy)
            } header: { Text("歌词") }
            Section(recording.isBusy ? "当前录制会话" : "练习录音") {
                if recording.isBusy {
                    Text(recording.route).font(.footnote)
                    if recording.state == .ready || recording.state == .interrupted {
                        Toggle("实时人声耳返", isOn: Binding(get: { recording.monitoringEnabled }, set: { recording.setMonitoringEnabled($0) })).disabled(!recording.monitoringAvailable)
                        Text(recording.monitoringExplanation).font(.footnote).foregroundStyle(.secondary)
                        Toggle("已确认收音和伴奏输出", isOn: $recording.routeConfirmed)
                        Button("倒数 3 秒后录音") { recording.start() }.disabled(!recording.routeConfirmed)
                        if recording.state == .interrupted { Button("重新检查录音会话") { Task { await recording.recheckInterruptedSession() } } }
                        Button("取消准备 / 稍后继续") { Task { await recording.leavePreparedSession() } }
                    }
                    if let countdown = recording.countdown { Text("\(countdown)").font(.largeTitle).monospacedDigit() }
                    if recording.state == .recording {
                        Text("正在录制…").foregroundStyle(.red)
                        Text("长按停止并保存").font(.headline).foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 54)
                            .background(.red, in: Capsule()).contentShape(Capsule())
                            .onLongPressGesture(minimumDuration: 1) { Task { await recording.finish() } }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { Task { await recording.finish() } }
                    } else {
                        Button("结束并保存") { Task { await recording.finish() } }.disabled(recording.state == .finalizing)
                    }
                } else {
                    Button { looping = false; Task { await recording.preflight(practice: true) } } label: { Label("准备练习录音", systemImage: "mic") }
                }
                ForEach(project?.takes.filter(\.isPractice) ?? []) { take in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(take.name).font(.headline)
                        HStack {
                            Button("回听原声") { Task { await listen(take) } }.disabled(recording.isBusy)
                            Spacer()
                            Button(take.promotedTakeID == nil ? "转为正式 Audio Take" : "打开正式 Take") {
                                Task { do { try await store.promote(take.id) } catch { store.report(error) } }
                            }.disabled(recording.isBusy)
                        }
                    }
                }
            }
        }
        .onChange(of: project?.arrangement?.semitones) { _, value in playback.semitones = value ?? 0 }
        .onChange(of: store.selectedID) { _, _ in looping = false; playback.loop = nil }
        .onChange(of: project?.arrangementID) { _, _ in looping = false; playback.loop = nil }
        .sheet(isPresented: $lyrics) { NavigationStack { LyricsEditor(forTake: false) } }
        .sheet(isPresented: $showPreview) { if let preview { PlayerSheet(title: "练习原始人声", player: preview) } }
    }
    func updateLoop() {
        guard looping, let project, project.loopEnd > project.loopStart else { playback.loop = nil; return }
        playback.loop = project.loopStart...project.loopEnd
    }
    func listen(_ take: Take) async {
        guard !recording.isBusy, var project else { return }; project.edit = EditGraph(); project.edit.selectedTakeID = take.id
        playback.stop(keepPosition: true)
        do {
            let (composition, _) = try await VideoComposer.composition(project: project, root: store.repository.directory(project.id), mix: nil, raw: true)
            guard !recording.isBusy else { return }
            preview = AVPlayer(playerItem: AVPlayerItem(asset: composition)); showPreview = true
        } catch { store.report(error) }
    }
}

func clock(_ seconds: Double) -> String {
    let safe = seconds.isFinite ? max(0, seconds) : 0
    return String(format: "%02d:%02d", Int(safe) / 60, Int(safe) % 60)
}

struct LyricsDisplay: View {
    let lyrics: Lyrics
    let position: Double
    var body: some View {
        if lyrics.lines.isEmpty {
            Text("添加 TXT 或 LRC 歌词，也可直接粘贴。").foregroundStyle(.secondary)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { index, line in
                            Text(line.text).font(.title3).fontWeight(lyrics.activeIndex(at: position) == index ? .semibold : .regular)
                                .foregroundStyle(lyrics.activeIndex(at: position) == index ? Color.primary : Color.secondary).id(index)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(.vertical, 8)
                }.frame(minHeight: 160, maxHeight: 260)
                    .onChange(of: lyrics.activeIndex(at: position)) { _, index in if let index { proxy.scrollTo(index, anchor: .center) } }
            }
            if !lyrics.isTimed { Text("纯文本：手动滚动，尚无同步时间轴。").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct LyricsEditor: View {
    @EnvironmentObject var store: StudioStore
    let forTake: Bool
    var body: some View { LyricsEditorPanel(store: store, playback: store.playback, forTake: forTake) }
}

struct LyricsEditorPanel: View {
    @ObservedObject var store: StudioStore
    @ObservedObject var playback: PlaybackEngine
    @Environment(\.dismiss) var dismiss
    let forTake: Bool
    @State private var text = ""
    @State private var picker = false
    @State private var warning = ""
    var body: some View {
        List {
            Section("试听与定位") {
                HStack {
                    Button(playback.playing ? "暂停" : "播放伴奏") {
                        do {
                            if playback.playing { playback.stop(keepPosition: true) }
                            else { try playback.activatePlaybackSession(); try store.preparePlayback(for: forTake ? store.selected?.selectedTake : nil); try playback.play() }
                        } catch { store.report(error) }
                    }
                    Spacer(); Text(clock(playback.position)).monospacedDigit()
                }
                Slider(value: Binding(get: { playback.position }, set: { value in do { try playback.seek(value) } catch { store.report(error) } }), in: 0...max(1, playback.duration)).accessibilityLabel("歌词标记位置")
            }.disabled(store.recording.isBusy)
            Section("粘贴 TXT / LRC") {
                TextEditor(text: $text).frame(minHeight: 150).accessibilityLabel("歌词文本")
                Button("读取文字并保留 LRC 时间点") {
                    let result = LRCParser.parse(text); warning = result.warnings.joined(separator: "\n")
                    store.arrangementBinding(\.lyrics, fallback: Lyrics(), forTake: forTake).wrappedValue = result.lyrics
                }
                Button("从文件导入") { picker = true }
                if !warning.isEmpty { Text(warning).font(.footnote).foregroundStyle(.orange) }
            }
            Section("逐句时间点（歌曲时间）") {
                Text("播放伴奏到这一句开始时，点「标记」。时间点需要按歌词顺序递增。只在全部句子完成标记后开放字幕导出。").font(.footnote).foregroundStyle(.secondary)
                ForEach(current.lines) { line in
                    VStack(alignment: .leading) {
                        Text(line.text)
                        HStack {
                            TextField("秒", value: lineBinding(line.id), format: .number.precision(.fractionLength(2))).keyboardType(.decimalPad)
                            Button("标记 \(clock(store.playback.position))") { set(line.id, time: store.playback.position) }
                        }
                    }
                }
                HStack {
                    Text("整体偏移（秒）")
                    TextField("偏移", value: offsetBinding, format: .number.precision(.fractionLength(2))).keyboardType(.numbersAndPunctuation)
                }
                Label(current.isTimed ? "逐句时间轴可用于字幕" : "仍需标记或修正时间点", systemImage: current.isTimed ? "checkmark.circle" : "clock")
            }
        }
        .navigationTitle("歌词时间轴").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { Task { do { try await store.flush(); dismiss() } catch { store.report(error) } } } } }
        .onAppear { text = current.lrc() }
        .fileImporter(isPresented: $picker, allowedContentTypes: [.plainText, .text, .data]) { result in
            do {
                let url = try result.get(), access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard try FileIntegrity.size(url) < 2 * 1024 * 1024 else { throw StudioError("歌词文件超过 2 MB，请选择纯文本文件。") }
                text = try String(contentsOf: url, encoding: .utf8)
                let result = LRCParser.parse(text); warning = result.warnings.joined(separator: "\n")
                store.arrangementBinding(\.lyrics, fallback: Lyrics(), forTake: forTake).wrappedValue = result.lyrics
            } catch { store.report(error) }
        }
    }
    var current: Lyrics { store.arrangementBinding(\.lyrics, fallback: Lyrics(), forTake: forTake).wrappedValue }
    var offsetBinding: Binding<Double> {
        Binding(get: { current.offset }, set: { value in var lyrics = current; lyrics.offset = value; store.arrangementBinding(\.lyrics, fallback: Lyrics(), forTake: forTake).wrappedValue = lyrics })
    }
    func lineBinding(_ id: UUID) -> Binding<Double?> {
        Binding(get: { current.lines.first { $0.id == id }?.time }, set: { set(id, time: $0) })
    }
    func set(_ id: UUID, time: Double?) {
        var lyrics = current
        if let index = lyrics.lines.firstIndex(where: { $0.id == id }) { lyrics.lines[index].time = time }
        store.arrangementBinding(\.lyrics, fallback: Lyrics(), forTake: forTake).wrappedValue = lyrics
    }
}

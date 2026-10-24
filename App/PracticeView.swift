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
                Button { lyrics = true } label: { Label(project?.arrangement?.lyrics.lines.isEmpty == false ? "编辑歌词" : "添加歌词", systemImage: "text.badge.plus") }
                    .accessibilityIdentifier("practice-lyrics").disabled(recording.isBusy)
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
    var maximumHeight: CGFloat = 260
    var body: some View {
        if lyrics.lines.isEmpty {
            Text("导入 TXT / LRC，或直接粘贴歌词。").foregroundStyle(.secondary)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { index, line in
                            Text(line.text).font(.title3)
                                .fontWeight(lyrics.isTimed && lyrics.activeIndex(at: position) == index ? .semibold : .regular)
                                .foregroundStyle(!lyrics.isTimed || lyrics.activeIndex(at: position) == index ? Color.primary : Color.secondary)
                                .id(index).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(.vertical, 8)
                }.frame(minHeight: 120, maxHeight: maximumHeight)
                    .onChange(of: lyrics.activeIndex(at: position)) { _, index in
                        guard lyrics.isTimed else { return }
                        proxy.scrollTo(index ?? 0, anchor: index == nil ? .top : .center)
                    }
                    .onChange(of: position) { old, new in
                        if new < old && new == 0 { proxy.scrollTo(0, anchor: .top) }
                    }
            }
            if !lyrics.isTimed { Text("纯文本歌词 · 可手动滚动").font(.caption).foregroundStyle(.secondary) }
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
    @State private var appliedText = ""
    @State private var draft = Lyrics()
    @State private var projectID: UUID?
    @State private var arrangementID: UUID?
    @State private var picker = false
    @State private var warning = ""
    @State private var problem: String?
    @State private var saving = false
    @State private var loaded = false
    var body: some View {
        List {
            Section {
                TextEditor(text: $text).frame(minHeight: 190)
                    .accessibilityLabel("歌词文本").accessibilityIdentifier("lyrics-text")
                HStack {
                    Button { picker = true } label: { Label("导入 TXT / LRC", systemImage: "doc.badge.plus") }
                        .accessibilityIdentifier("lyrics-import")
                    Spacer()
                    PasteButton(payloadType: String.self) { strings in
                        text = strings.joined(separator: "\n"); applyText()
                    }.labelStyle(.titleOnly)
                }.buttonStyle(.bordered)
                Text("可直接在上方粘贴或修改。点右上角「保存」即可应用；练习与录制共用当前伴奏版本的歌词。").font(.footnote).foregroundStyle(.secondary)
                if !warning.isEmpty { Label(warning, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange) }
            } header: { Text("歌词文字") }
            Section {
                Button("读取文字并预览时间点") { applyText() }
                Label(draft.isTimed ? "已读取逐句时间轴" : "普通文本可直接保存并手动滚动", systemImage: draft.isTimed ? "checkmark.circle" : "text.alignleft")
                    .font(.footnote).foregroundStyle(.secondary)
                DisclosureGroup("试听与手动标记时间点") {
                    HStack {
                        Button(playback.playing ? "暂停" : "播放伴奏") {
                            do {
                                if playback.playing { playback.stop(keepPosition: true) }
                                else { try playback.activatePlaybackSession(); try store.preparePlayback(for: forTake ? store.selected?.selectedTake : nil); try playback.play() }
                            } catch { problem = error.localizedDescription }
                        }.disabled(store.recording.isBusy)
                        Spacer(); Text(clock(playback.position)).monospacedDigit()
                    }
                    Slider(value: Binding(get: { playback.position }, set: { value in
                        do { try playback.seek(value) } catch { problem = error.localizedDescription }
                    }), in: 0...max(1, playback.duration)).accessibilityLabel("歌词标记位置").disabled(store.recording.isBusy)
                    Text("修改文字后先点「读取文字」。播放到每句开始时标记，全部标记后可用于同步及字幕导出。").font(.footnote).foregroundStyle(.secondary)
                    ForEach(draft.lines) { line in
                        VStack(alignment: .leading) {
                            Text(line.text)
                            HStack {
                                TextField("秒", value: lineBinding(line.id), format: .number.precision(.fractionLength(2))).keyboardType(.decimalPad)
                                Button("标记 " + clock(playback.position)) { set(line.id, time: playback.position) }
                            }
                        }.disabled(text != appliedText)
                    }
                    HStack {
                        Text("整体偏移（秒）")
                        TextField("偏移", value: Binding(get: { draft.offset }, set: { draft.offset = $0; refreshText() }), format: .number.precision(.fractionLength(2))).keyboardType(.numbersAndPunctuation)
                    }.disabled(text != appliedText)
                }
            } header: { Text("同步（可选）") }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("编辑歌词").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消", role: .cancel) { dismiss() }.disabled(saving) }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "保存中…" : "保存") { Task { await save() } }
                    .accessibilityIdentifier("lyrics-save").disabled(saving || !loaded)
            }
        }
        .disabled(saving).interactiveDismissDisabled(saving)
        .onAppear { load() }
        .alert("歌词未能保存或导入", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("知道了", role: .cancel) { problem = nil }
        } message: { Text(problem ?? "") }
        // Some Files providers identify LRC as generic data. Validate extension and bytes ourselves.
        .fileImporter(isPresented: $picker, allowedContentTypes: [.plainText, .text, .data]) { result in
            do {
                let url = try result.get(), access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                text = try LyricsDocument.read(url); applyText()
            } catch {
                let failure = error as NSError
                if failure.domain != NSCocoaErrorDomain || failure.code != CocoaError.Code.userCancelled.rawValue { problem = error.localizedDescription }
            }
        }
    }
    private func load() {
        guard !loaded, let project = store.selected else { return }
        let id = forTake ? project.selectedTake?.arrangementID ?? project.arrangementID : project.arrangementID
        guard let arrangement = project.arrangements.first(where: { $0.id == id }) else { problem = "找不到当前伴奏版本。"; return }
        projectID = project.id; arrangementID = id; draft = arrangement.lyrics
        refreshText(); loaded = true
    }
    private func refreshText() { text = LyricsDocument.editableText(draft); appliedText = text }
    private func applyText() {
        do {
            let result = LRCParser.parse(try LyricsDocument.validate(text))
            guard !result.lyrics.lines.isEmpty else { throw StudioError("没有读到歌词文字，请检查文件内容或粘贴文本。") }
            draft = result.lyrics; appliedText = text; warning = result.warnings.joined(separator: "\n")
        } catch { problem = error.localizedDescription }
    }
    private func save() async {
        guard let projectID, let arrangementID else { problem = "工程或伴奏版本不可用。"; return }
        saving = true; defer { saving = false }
        do {
            // Save always consumes pasted/edited text; there is no hidden Apply prerequisite.
            if text != appliedText { draft = LRCParser.parse(try LyricsDocument.validate(text)).lyrics }
            try await store.saveLyrics(draft, projectID: projectID, arrangementID: arrangementID)
            dismiss()
        } catch { problem = error.localizedDescription }
    }
    private func lineBinding(_ id: UUID) -> Binding<Double?> {
        Binding(get: { draft.lines.first { $0.id == id }?.time }, set: { set(id, time: $0) })
    }
    private func set(_ id: UUID, time: Double?) {
        if let index = draft.lines.firstIndex(where: { $0.id == id }) { draft.lines[index].time = time; refreshText() }
    }
}

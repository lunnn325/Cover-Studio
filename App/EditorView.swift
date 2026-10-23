import SwiftUI
import AVKit
import PhotosUI
import UniformTypeIdentifiers
import CoreTransferable
import CoverCore

struct EditorView: View {
    @EnvironmentObject var store: StudioStore
    var body: some View {
        if let project = store.selected, !project.archived {
            EditorPanel(store: store, exports: store.exports)
        } else { EmptyProjectView(archived: store.selected?.archived == true) }
    }
}

struct EditorPanel: View {
    @ObservedObject var store: StudioStore
    @ObservedObject var exports: ExportService
    @State private var exportSheet = false
    @State private var lyricsSheet = false
    @State private var previewSheet = false
    @State private var rawPreview = false
    @State private var mediaPicker = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedMovie: PhotosPickerItem?
    @State private var player: AVPlayer?
    @State private var dubbing = false
    var project: StudioProject? { store.selected }
    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 850 {
                HStack(spacing: 0) {
                    VStack(spacing: 16) { previewControls; Spacer() }.padding().frame(width: geometry.size.width * 0.42)
                    Divider()
                    List { controls }
                }
            } else {
                List { Section { previewControls }; controls }
            }
        }
        .disabled(store.recording.isBusy)
        .sheet(isPresented: $exportSheet) { NavigationStack { ExportView(service: exports) } }
        .sheet(isPresented: $lyricsSheet) { NavigationStack { LyricsEditor(forTake: true) } }
        .sheet(isPresented: $rawPreview) { NavigationStack { TakePreviewView(takeID: project?.edit.selectedTakeID) } }
        .sheet(isPresented: $previewSheet) { if let player { PlayerSheet(title: "后期混音试听", player: player) } }
        .sheet(isPresented: $dubbing) { NavigationStack { DubbingView() } }
        .fileImporter(isPresented: $mediaPicker, allowedContentTypes: [.image, .movie]) { result in
            Task {
                do {
                    let url = try result.get()
                    let image = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
                    try await store.importVisual(url, image: image)
                } catch { store.report(error) }
            }
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.95) else { throw StudioError("照片读取失败，请改用文件导入。") }
                    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
                    try jpeg.write(to: temporary); try await store.importVisual(temporary, image: true)
                } catch { store.report(error) }
            }
        }
        .onChange(of: selectedMovie) { _, item in
            guard let item else { return }
            Task {
                do {
                    guard let file = try await item.loadTransferable(type: PickedMovie.self) else { throw StudioError("相册视频无法读取，请使用文件导入。") }
                    try await store.importVisual(file.url, image: false)
                } catch { store.report(error) }
            }
        }
    }
    @ViewBuilder var previewControls: some View {
        if let take = project?.selectedTake {
            Image(systemName: take.kind == .video ? "video" : "waveform").font(.largeTitle).foregroundStyle(.secondary).frame(height: 70)
            Text(take.name).font(.title2.weight(.semibold))
            Text("\(take.segments.count) 个片段 · 录制变调 \(take.semitones) 半音").font(.subheadline).foregroundStyle(.secondary)
            Button("播放原始 Take") { rawPreview = true }.buttonStyle(.bordered)
            Button {
                guard let project else { return }
                Task {
                    do { try await store.flush(); let url = try await exports.previewMix(project: project, root: store.repository.directory(project.id)); player = AVPlayer(url: url); previewSheet = true }
                    catch { store.report(error) }
                }
            } label: { Label("试听当前混音", systemImage: "headphones") }.buttonStyle(.borderedProminent).disabled(exports.working)
            if exports.working { ProgressView(exports.stage) }
            Button("选择输出与导出") { exportSheet = true }.buttonStyle(.bordered).disabled(exports.working)
        } else {
            ContentUnavailableView("还没有正式 Take", systemImage: "waveform", description: Text("先录制，或把满意的练习录音转为 Audio Take。"))
        }
    }
    @ViewBuilder var controls: some View {
        Section {
            Button("撤销上次后期修改") { store.undoEdit() }.disabled(!store.canUndoEdit || exports.working)
        }
        Section("Take") {
            ForEach(project?.takes.filter { !$0.isPractice } ?? []) { take in
                Button {
                    store.update { $0.edit.selectedTakeID = take.id; $0.edit.trimStart = 0; $0.edit.trimEnd = nil }
                } label: {
                    HStack {
                        Label(take.name, systemImage: take.kind == .video ? "video" : "waveform")
                        Spacer()
                        if take.favorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                        if project?.edit.selectedTakeID == take.id { Image(systemName: "checkmark") }
                    }
                }
            }
        }
        if project?.selectedTake != nil {
            Section("混音") {
                gainSlider("人声", value: store.binding(\.edit.vocalGain, fallback: 1), range: 0...2)
                gainSlider("伴奏", value: store.binding(\.edit.backingGain, fallback: 0.7), range: 0...2)
                HStack {
                    Button("自然") { store.update { $0.edit.bassDB = 0; $0.edit.presenceDB = 0; $0.edit.reverb = 8; $0.edit.highPassHz = 70 } }
                    Spacer()
                    Button("温暖") { store.update { $0.edit.bassDB = 2; $0.edit.presenceDB = -1; $0.edit.reverb = 5; $0.edit.highPassHz = 80 } }
                    Spacer()
                    Button("轻混响") { store.update { $0.edit.bassDB = 0; $0.edit.presenceDB = 1; $0.edit.reverb = 18; $0.edit.highPassHz = 70 } }
                }
                DisclosureGroup("高级音频") {
                    gainSlider("低频 EQ（dB）", value: store.binding(\.edit.bassDB, fallback: 0), range: -12...12)
                    gainSlider("清晰度 EQ（dB）", value: store.binding(\.edit.presenceDB, fallback: 0), range: -12...12)
                    gainSlider("混响（%）", value: store.binding(\.edit.reverb, fallback: 8), range: 0...50)
                    gainSlider("低频噪声过滤（Hz）", value: store.binding(\.edit.highPassHz, fallback: 70), range: 20...250)
                    Text("基础降噪采用可调高通，只减少低频杂音，不承诺去除所有环境噪声。自动修音尚未开放。").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("同步与裁剪") {
                numberField("人声固定偏移（秒）", store.binding(\.edit.syncOffset, fallback: 0))
                Text("正值延后人声。时间戳用于记录设备基准；实际声学延迟未自动校准，请试听微调。").font(.footnote).foregroundStyle(.secondary)
                numberField("起点（歌曲秒数）", store.binding(\.edit.trimStart, fallback: 0))
                HStack {
                    Text("终点（留空为录制结束）")
                    TextField("秒", value: store.binding(\.edit.trimEnd, fallback: nil), format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                }
                Button("重置偏移与裁剪") { store.update { $0.edit.syncOffset = 0; $0.edit.trimStart = 0; $0.edit.trimEnd = nil; $0.edit.segmentStartOverrides = [:] } }
                if let take = project?.selectedTake, take.segments.count > 1 {
                    DisclosureGroup("手动接唱 / 拼接点") {
                        Text("后录片段覆盖重叠区间，源文件保留。请预览切点，画面可能有跳切。").font(.footnote).foregroundStyle(.secondary)
                        ForEach(take.segments) { segment in
                            numberField("片段 \(take.segments.firstIndex(where: { $0.id == segment.id })! + 1) 开始秒数", segmentBinding(segment))
                        }
                    }
                }
            }
            Section("画面") {
                Picker("裁切比例", selection: store.binding(\.edit.aspect, fallback: 9.0/16)) {
                    Text("9:16").tag(9.0/16); Text("16:9").tag(16.0/9); Text("1:1").tag(1.0)
                }
                Toggle("导出镜像", isOn: store.binding(\.edit.mirrorExport, fallback: false))
                PhotosPicker(selection: $selectedPhoto, matching: .images) { Label("从相册选择照片背景", systemImage: "photo") }
                PhotosPicker(selection: $selectedMovie, matching: .videos) { Label("从相册选择补拍视频", systemImage: "video") }
                Button("从文件导入照片 / 补拍视频") { mediaPicker = true }
                Button("拍摄对口型画面") { dubbing = true }
                if project?.edit.visualAssetID != nil { numberField("补拍画面偏移（秒，正值延后）", store.binding(\.edit.visualOffset, fallback: 0)) }
                if project?.edit.visualAssetID != nil { Button("恢复 Take 原始画面") { store.update { $0.edit.visualAssetID = nil } } }
                Text("补拍和照片只替换输出画面，不覆盖原始人声。默认输出 1080p；4K 管线未验证，暂不开放。").font(.footnote).foregroundStyle(.secondary)
            }
            Section("字幕") {
                Button("逐句标记 / 修订歌词") { lyricsSheet = true }
                Picker("字体", selection: store.binding(\.edit.subtitleStyle.fontName, fallback: "PingFangSC-Semibold")) {
                    Text("苹方").tag("PingFangSC-Semibold"); Text("黑体").tag("HiraginoSans-W6")
                }
                gainSlider("字号", value: store.binding(\.edit.subtitleStyle.size, fallback: 42), range: 24...80)
                gainSlider("距底部比例", value: store.binding(\.edit.subtitleStyle.verticalPosition, fallback: 0.14), range: 0.05...0.8)
                Toggle("白色文字（关闭为黄色）", isOn: store.binding(\.edit.subtitleStyle.whiteText, fallback: true))
                Toggle("阴影", isOn: store.binding(\.edit.subtitleStyle.shadow, fallback: true))
                numberField("字幕开始显示（歌曲秒数）", store.binding(\.edit.subtitleStart, fallback: 0))
                HStack {
                    Text("字幕结束显示（留空至结尾）")
                    TextField("秒", value: store.binding(\.edit.subtitleEnd, fallback: nil), format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                }
                Text("录制歌词不会写入原始视频。字幕仅在选择带字幕导出时合成。").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
    func segmentBinding(_ segment: RecordingSegment) -> Binding<Double> {
        Binding(get: { project?.edit.segmentStartOverrides[segment.id] ?? segment.songStart.seconds }, set: { value in store.update { $0.edit.segmentStartOverrides[segment.id] = value } })
    }
    func gainSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) { LabeledContent(title, value: String(format: "%.2f", value.wrappedValue)); Slider(value: value, in: range).accessibilityLabel(title) }
    }
    func numberField(_ title: String, _ value: Binding<Double>) -> some View {
        HStack { Text(title); TextField("秒", value: value, format: .number.precision(.fractionLength(3))).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing) }
    }
}

struct PickedMovie: Transferable {
    var url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            try FileManager.default.copyItem(at: received.file, to: url)
            return PickedMovie(url: url)
        }
    }
}

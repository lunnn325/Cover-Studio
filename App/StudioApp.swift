import SwiftUI
import AVKit
import UniformTypeIdentifiers
import CoverCore

@main struct MyCoverStudioApp: App {
    @StateObject private var bootstrap = StudioBootstrap()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            StudioLaunchView(bootstrap: bootstrap)
                .task { UIDevice.current.isBatteryMonitoringEnabled = true; await bootstrap.open() }
                .onOpenURL { url in Task { await bootstrap.openArchive(url) } }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active, let store = bootstrap.store { Task { do { try await store.flush() } catch { store.report(error) } } }
                }
        }
    }
}

extension UTType {
    static let coverProject = UTType(exportedAs: "studio.mycover.project", conformingTo: .data)
}

extension StudioStore {
    func binding<Value>(_ path: WritableKeyPath<StudioProject, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { self.selected?[keyPath: path] ?? fallback }, set: { value in self.update { $0[keyPath: path] = value } })
    }
    func arrangementBinding<Value>(_ path: WritableKeyPath<Arrangement, Value>, fallback: Value, forTake: Bool = false) -> Binding<Value> {
        Binding(get: {
            guard let project = self.selected else { return fallback }
            let id = forTake ? project.selectedTake?.arrangementID ?? project.arrangementID : project.arrangementID
            return project.arrangements.first { $0.id == id }?[keyPath: path] ?? fallback
        }, set: { value in
            self.update { project in
                let id = forTake ? project.selectedTake?.arrangementID ?? project.arrangementID : project.arrangementID
                if let index = project.arrangements.firstIndex(where: { $0.id == id }) { project.arrangements[index][keyPath: path] = value }
            }
        })
    }
}

struct StudioRoot: View {
    @EnvironmentObject var store: StudioStore
    @State private var importing = false
    @State private var settings = false
    @State private var tab = 0
    @State private var processing = false
    @State private var recordingLocked = false
    var body: some View {
        TabView(selection: Binding(get: { tab }, set: { if !recordingLocked { tab = $0 } })) {
            NavigationStack { PracticeView().navigationTitle("练习").toolbar { commonToolbar } }
                .tabItem { Label("练习", systemImage: "waveform") }.tag(0)
            NavigationStack { RecordView().navigationTitle("录制").toolbar { commonToolbar } }
                .tabItem { Label("录制", systemImage: "record.circle") }.tag(1)
            NavigationStack { EditorView().navigationTitle("编辑").toolbar { commonToolbar } }
                .tabItem { Label("编辑", systemImage: "slider.horizontal.3") }.tag(2)
            NavigationStack { LibraryView().navigationTitle("作品库").toolbar { commonToolbar } }
                .tabItem { Label("作品库", systemImage: "square.stack") }.tag(3)
        }
        .tint(.indigo)
        .onReceive(store.exports.$working) { processing = $0 }
        .onReceive(store.recording.$controlsLocked) { recordingLocked = $0 }
        .disabled(store.busy)
        .sheet(isPresented: $importing) { ImportSongView() }
        .sheet(isPresented: $settings) { NavigationStack { SettingsView() } }
        .alert("需要处理", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("知道了", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .alert("工程提示", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button("知道了", role: .cancel) { store.notice = nil }
        } message: { Text(store.notice ?? "") }
    }
    @ToolbarContentBuilder var commonToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                ForEach(store.projects.filter { !$0.archived }) { project in
                    Button(project.song.title) { Task { await store.select(project.id) } }
                }
            } label: { Label(store.selected?.song.title ?? "My Cover Studio", systemImage: "music.note") }
                .disabled(store.recording.isBusy || store.projects.isEmpty || store.busy || processing)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { importing = true } label: { Label("导入伴奏", systemImage: "plus") }.disabled(store.recording.isBusy || processing)
            Button { settings = true } label: { Label("设置", systemImage: "gearshape") }.disabled(recordingLocked)
        }
    }
}

struct EmptyProjectView: View {
    var archived = false
    var body: some View {
        ContentUnavailableView(archived ? "工程已归档" : "从一首伴奏开始", systemImage: archived ? "archivebox" : "music.note",
                               description: Text(archived ? "从作品库选择外部工程包恢复。" : "点右上角 + 导入本地 MP3、M4A 或 WAV。\n一台设备即可练习、录制与编辑。"))
    }
}

struct ImportSongView: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) var dismiss
    @State private var picker = false
    @State private var url: URL?
    @State private var title = ""
    @State private var artist = ""
    @State private var isBacking = true
    @State private var newVersion = false
    @State private var importing = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { picker = true } label: { Label(url?.lastPathComponent ?? "选择本地音频", systemImage: "doc.badge.plus") }
                    TextField("歌曲名", text: $title)
                    TextField("歌手", text: $artist)
                }
                Section("音频内容") {
                    Picker("来源", selection: $isBacking) { Text("已有伴奏").tag(true); Text("需要去原唱").tag(false) }.pickerStyle(.segmented)
                    if !isBacking { Text("原曲将原样保存。AI 分离尚未集成；可导入在 iPad 或其他工具准备好的伴奏，不会自动上传。").font(.footnote).foregroundStyle(.secondary) }
                    if store.selected != nil && store.selected?.archived == false { Toggle("作为当前歌曲的新伴奏版本", isOn: $newVersion) }
                    if newVersion { Text("旧 Take 仍绑定原伴奏；新版本从独立歌词时间轴开始。").font(.footnote).foregroundStyle(.secondary) }
                }
                if importing { ProgressView("正在复制并校验音频…") }
            }
            .navigationTitle("导入歌曲").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(importing) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        guard let url else { return }; importing = true
                        Task {
                            do { try await store.importAudio(url, isBacking: isBacking, newArrangement: newVersion, title: title, artist: artist); dismiss() }
                            catch { store.report(error) }; importing = false
                        }
                    }.disabled(url == nil || importing)
                }
            }
            .fileImporter(isPresented: $picker, allowedContentTypes: [.audio]) { result in
                switch result {
                case .success(let selected): url = selected; if title.isEmpty { title = selected.deletingPathExtension().lastPathComponent }
                case .failure(let error): store.report(error)
                }
            }
            .interactiveDismissDisabled(importing)
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: urls, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct DocumentExportPicker: UIViewControllerRepresentable {
    var urls: [URL]
    var completed: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completed) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true); picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completed: (Bool) -> Void
        init(_ completed: @escaping (Bool) -> Void) { self.completed = completed }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completed(!urls.isEmpty) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completed(false) }
    }
}

struct PlayerSheet: View {
    @Environment(\.dismiss) var dismiss
    let title: String
    let player: AVPlayer
    var body: some View {
        NavigationStack {
            VideoPlayer(player: player).navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { player.pause(); dismiss() } } }
        }.onDisappear { player.pause() }
    }
}

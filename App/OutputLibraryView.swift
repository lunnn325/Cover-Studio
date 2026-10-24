import SwiftUI
import AVKit
import CoverCore

struct OutputLibraryView: View {
    @EnvironmentObject var store: StudioStore
    var body: some View { OutputLibraryPanel(store: store, service: store.exports) }
}

struct OutputLibraryPanel: View {
    @ObservedObject var store: StudioStore
    @ObservedObject var service: ExportService
    @Environment(\.dismiss) var dismiss
    @State private var outputs: [ExportedFile] = []
    @State private var listedProjectID: UUID?
    @State private var pending: ExportedFile?
    @State private var pendingProjectID: UUID?
    @State private var firstConfirm = false
    @State private var finalConfirm = false
    @State private var sharing = false
    @State private var saving = false
    @State private var urls: [URL] = []
    @State private var preview = false
    @State private var player: AVPlayer?
    @State private var lyrics: String?
    @State private var showingLyrics = false
    @State private var loading = false
    var blocked: Bool { service.working || store.recording.isBusy || store.auxiliaryRecording || store.busy }
    var body: some View {
        List {
            if loading { ProgressView("正在读取成品目录…") }
            Section("已完成导出") {
                ForEach(outputs.filter(\.completed)) { output in outputRow(output) }
                if !loading && !outputs.contains(where: \.completed) { Text("还没有可在本机读取的已登记成品。").foregroundStyle(.secondary) }
            }
            if outputs.contains(where: { !$0.completed }) {
                Section("未登记文件") {
                    Text("可能是旧版成品或未完成的输出。不会自动标记完成，也不纳入“包含成品”的工程备份；可先预览核对，再保存到 Files 或确认删除。").font(.footnote).foregroundStyle(.secondary)
                    ForEach(outputs.filter { !$0.completed }) { output in outputRow(output) }
                }
            }
        }
        .disabled(blocked)
        .navigationTitle("导出成品").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(store.busy) } }
        .task(id: store.selectedID) { await refresh() }
        .sheet(isPresented: $sharing) { ShareSheet(urls: urls) }
        .sheet(isPresented: $saving) { DocumentExportPicker(urls: urls) { success in
            saving = false
            if success { store.notice = "已交给文件提供者；不代表云端上传完成。" }
        } }
        .sheet(isPresented: $preview) { if let player { PlayerSheet(title: "成品预览", player: player) } }
        .sheet(isPresented: $showingLyrics) { NavigationStack {
            ScrollView { Text(lyrics ?? "").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                .navigationTitle("歌词文件").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingLyrics = false } } }
        } }
        .confirmationDialog("删除所选导出文件？", isPresented: $firstConfirm, titleVisibility: .visible) {
            Button("取消", role: .cancel) {}
            Button("继续查看最终确认", role: .destructive) { finalConfirm = true }
        } message: { Text("\(pending?.name ?? "") · \(bytes(pending?.bytes ?? 0))。只处理所选导出文件，原始伴奏、人声和画面不受影响。") }
        .alert("最终确认：永久删除所选成品", isPresented: $finalConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认删除", role: .destructive) { Task { await removeSelected() } }
        } message: { Text("\(pending?.name ?? "")。此文件将从本机移除；已登记的完成状态也会更新。未登记文件可能无法重新生成，请先核对或保存副本。") }
    }
    private func outputRow(_ output: ExportedFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(output.label, value: bytes(output.bytes))
            Text(output.name).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let date = output.modifiedAt { Text(date, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("预览") { Task { await previewOutput(output) } }
                Button("保存到 Files") { do { urls = [try fileURL(output)]; saving = true } catch { store.report(error) } }
                Button("分享") { do { urls = [try fileURL(output)]; sharing = true } catch { store.report(error) } }
            }
            Button("删除此文件…", role: .destructive) { pending = output; pendingProjectID = listedProjectID; firstConfirm = true }
        }.buttonStyle(.borderless)
    }
    private func fileURL(_ output: ExportedFile) throws -> URL {
        guard let project = store.selected, project.id == listedProjectID, ExportCatalog.isOutputPath(output.path) else { throw StudioError("工程已变化，请重新打开成品目录。") }
        let url = try ProjectRules.mediaURL(output.path, root: store.repository.directory(project.id))
        _ = try FileIntegrity.size(url)
        return url
    }
    private func previewOutput(_ output: ExportedFile) async {
        do {
            let url = try fileURL(output)
            if ["lrc", "txt"].contains(url.pathExtension.lowercased()) {
                guard try FileIntegrity.size(url) <= 2 * 1024 * 1024, let text = String(data: try Data(contentsOf: url), encoding: .utf8) else { throw StudioError("歌词过大或不是 UTF-8，请保存到 Files 后查看。") }
                lyrics = text; showingLyrics = true
            } else {
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration).seconds
                let tracks = try await asset.load(.tracks)
                guard duration.isFinite, duration > 0, !tracks.isEmpty else { throw StudioError("此文件没有可读取的音视频，可能是未完成输出；原文件已保留。") }
                guard store.selectedID == listedProjectID else { throw StudioError("工程已变化，请重新打开成品目录。") }
                store.playback.suspendEngine(); player = AVPlayer(url: url); preview = true
            }
        } catch { store.report(error) }
    }
    private func refresh() async {
        guard let project = store.selected else { outputs = []; return }
        loading = true; defer { loading = false }
        let root = store.repository.directory(project.id)
        do {
            let files = try await Task.detached { try ExportCatalog.outputs(root: root, assets: project.assets) }.value
            guard !Task.isCancelled, store.selectedID == project.id else { return }
            outputs = files; listedProjectID = project.id
        } catch { outputs = []; store.report(error) }
    }
    private func removeSelected() async {
        guard !blocked, let output = pending, let project = store.selected, project.id == pendingProjectID else { store.error = "请先结束当前操作，并重新确认所选文件。"; return }
        store.busy = true; defer { store.busy = false }
        do {
            var candidate = project
            candidate.assets.removeAll { $0.role == .export && ExportCatalog.samePath($0.path, output.path) }
            do { try ProjectRules.validate(candidate) }
            catch { throw StudioError("此导出文件仍被工程引用，已阻止删除。请先解除相关编辑依赖。") }
            if candidate.assets != project.assets && !project.archived {
                store.update { $0.assets = candidate.assets }; try await store.flush()
            }
            try ExportCatalog.removeOutput(path: output.path, root: store.repository.directory(project.id))
            service.load(root: store.repository.directory(project.id), projectID: project.id, exportedAssets: store.selected?.assets ?? [])
            pending = nil; await refresh()
        } catch { store.report(error); await refresh() }
    }
}

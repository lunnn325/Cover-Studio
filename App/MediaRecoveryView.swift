import SwiftUI
import AVKit
import CoverCore

struct MediaRecoveryView: View {
    @EnvironmentObject var store: StudioStore
    var body: some View { MediaRecoveryPanel(store: store, exports: store.exports) }
}

struct MediaRecoveryPanel: View {
    @ObservedObject var store: StudioStore
    @ObservedObject var exports: ExportService
    @Environment(\.dismiss) var dismiss
    @State private var files: [UnclaimedMediaFile] = []
    @State private var scopeID: UUID?
    @State private var pending: UnclaimedMediaFile?
    @State private var pendingID: UUID?
    @State private var firstConfirm = false
    @State private var finalConfirm = false
    @State private var saving = false
    @State private var urls: [URL] = []
    @State private var preview = false
    @State private var player: AVPlayer?
    @State private var loading = false
    var blocked: Bool { store.busy || store.recording.isBusy || store.auxiliaryRecording || exports.working }
    var pendingRecording: Bool {
        guard let id = store.selectedID else { return false }
        return FileManager.default.fileExists(atPath: store.repository.directory(id).appendingPathComponent("recording.json").path)
    }
    var body: some View {
        recoveryList
            .navigationTitle("保留原件").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(store.busy) } }
            .task(id: store.selectedID) { await refresh() }
            .sheet(isPresented: $saving) { DocumentExportPicker(urls: urls) { success in
                saving = false
                if success { store.notice = "原文件已交给 Files，云上传与文件可播放性仍未验证。" }
            } }
            .sheet(isPresented: $preview) { if let player { PlayerSheet(title: "原件预览", player: player) } }
            .confirmationDialog("删除此未引用原件？", isPresented: $firstConfirm, titleVisibility: .visible) {
                Button("取消", role: .cancel) {}
                Button("继续查看最终确认", role: .destructive) { finalConfirm = true }
            } message: { Text("\(pending?.name ?? "") · \(bytes(pending?.bytes ?? 0))。它可能是中断录制的唯一尾段，建议先另存或纳入完整包。") }
            .alert("最终确认：永久移除原件", isPresented: $finalConfirm) {
                Button("取消", role: .cancel) {}
                Button("确认删除这个文件", role: .destructive) { if let pending, let pendingID { Task { await process(pending, projectID: pendingID, remove: true) } } }
            } message: { Text("只删除 \(pending?.name ?? "")。此操作不可撤销；引用、路径和待恢复录制状态会再次检查。") }
            .overlay { if store.busy { ProgressView("正在保护原件与保存索引…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
    }
    private var recoveryList: some View {
        List {
            Section {
                Text("这里只列出没有被伴奏、Take 或当前画面引用的原件。未登记文件可能来自失败导入或中断尾段；文件存在不代表能播放或已同步。").font(.footnote).foregroundStyle(.secondary)
                Text("登记后完整工程包保留原始字节，精简/自定义包可能排除未引用原件。登记不会创建 Take 或修复容器。").font(.footnote).foregroundStyle(.secondary)
                if pendingRecording { Text("仍有待恢复录制。请先从作品库继续或保留文件并结束接唱，再清理原件。").font(.footnote).foregroundStyle(.orange) }
                if loading { ProgressView("正在读取原件…") }
            }
            ForEach(files) { file in fileRow(file) }
            if files.isEmpty && !loading { Text("没有未登记或未引用的原件。").foregroundStyle(.secondary) }
        }.disabled(blocked)
    }
    private func fileRow(_ file: UnclaimedMediaFile) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            LabeledContent(file.name, value: bytes(file.bytes))
            Text(file.assetID == nil ? "未登记：尚不在工程包内" : "已登记：完整包保留，当前编辑未引用").font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button("另存到 Files") { do { urls = [try fileURL(file)]; saving = true } catch { store.report(error) } }
                if ["mp4", "mov", "m4a", "wav", "mp3", "caf", "aac"].contains((file.path as NSString).pathExtension.lowercased()) {
                    Button("尝试预览") { Task { await tryPreview(file) } }
                }
            }
            if file.assetID == nil && store.selected?.archived == false {
                Button("登记进完整工程包") { if let scopeID { Task { await process(file, projectID: scopeID, remove: false) } } }
            }
            Button("删除此文件…", role: .destructive) { pending = file; pendingID = scopeID; firstConfirm = true }.disabled(pendingRecording)
        }.buttonStyle(.borderless)
    }
    private func fileURL(_ file: UnclaimedMediaFile) throws -> URL {
        guard !blocked, let id = store.selectedID, id == scopeID, file.path.hasPrefix("media/") else { throw StudioError("请先结束当前操作，或刷新后重试。") }
        let url = try ProjectFiles.url(file.path, root: store.repository.directory(id))
        _ = try FileIntegrity.size(url); return url
    }
    private func refresh() async {
        guard let project = store.selected else { return }
        loading = true; defer { loading = false }
        let root = store.repository.directory(project.id)
        do {
            let values = try await Task.detached { try ProjectFiles.unclaimedMedia(project: project, root: root) }.value
            guard !Task.isCancelled, store.selectedID == project.id else { return }
            files = values; scopeID = project.id
        } catch { files = []; store.report(error) }
    }
    private func process(_ file: UnclaimedMediaFile, projectID: UUID, remove: Bool) async {
        do { try await store.processUnclaimed(path: file.path, projectID: projectID, remove: remove); pending = nil; await refresh() }
        catch { store.report(error); await refresh() }
    }
    private func tryPreview(_ file: UnclaimedMediaFile) async {
        do {
            let url = try fileURL(file), asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds, tracks = try await asset.load(.tracks)
            guard duration.isFinite, duration > 0, !tracks.isEmpty else { throw StudioError("容器不能安全读取。原始字节已保留，可另存后尝试恢复；未标记为录制成功。") }
            guard !blocked, store.selectedID == scopeID else { throw StudioError("当前操作或工程已变化，请重新选择原件。") }
            store.playback.suspendEngine(); player = AVPlayer(url: url); preview = true
        } catch { store.report(error) }
    }
}

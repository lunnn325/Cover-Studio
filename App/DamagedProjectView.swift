import SwiftUI
import CoverCore

struct DamagedProjectView: View {
    @EnvironmentObject var store: StudioStore
    let issue: LibraryIssue
    var body: some View { DamagedProjectPanel(store: store, service: store.exports, issue: issue) }
}

struct DamagedProjectPanel: View {
    @ObservedObject var store: StudioStore
    @ObservedObject var service: ExportService
    @Environment(\.dismiss) var dismiss
    let issue: LibraryIssue
    @State private var files: [ProjectFile] = []
    @State private var candidate: IndexRecoveryCandidate?
    @State private var working = false
    @State private var stage = ""
    @State private var failure: String?
    @State private var message: String?
    @State private var confirm = false
    @State private var importing = false
    @State private var exporting = false
    @State private var urls: [URL] = []
    var blocked: Bool { working || store.busy || store.recording.isBusy || store.auxiliaryRecording || service.working }
    var canBrowseFiles: Bool { issue.projectID != nil || ProjectFiles.isRetainedDirectory(issue.directoryName) }
    var body: some View {
        contents
        .disabled(blocked)
        .overlay { if working { ProgressView(stage).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .navigationTitle("工程索引恢复").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(working) } }
        .interactiveDismissDisabled(working)
        .task { if canBrowseFiles { await refreshFiles() } }
        .confirmationDialog("根据上一版创建独立恢复副本？", isPresented: $confirm, titleVisibility: .visible) {
            Button("取消", role: .cancel) {}
            Button("保留原目录，创建恢复副本") { Task { await recover() } }
        } message: { Text("按已校验的上一版恢复编辑；未登记原件只保留字节，不推测缺失 Take 或同步。需要额外本地空间，原损坏目录继续保留。") }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.coverProject, .data]) { result in
            Task {
                do { try await store.restore(try result.get(), keepBoth: true); dismiss() }
                catch { failure = error.localizedDescription }
            }
        }
        .sheet(isPresented: $exporting) { DocumentExportPicker(urls: urls) { success in
            exporting = false
            if success { message = "副本已交给 Files，云端上传状态未验证。" }
        } }
    }
    private var contents: some View {
        List {
            Section("原目录已保留") {
                Text(issue.directoryName).font(.caption).textSelection(.enabled)
                Text(issue.reason).font(.footnote).foregroundStyle(.secondary)
                Text("不会自动回退索引、覆盖或删除原件。上一版可能缺少最近修改；恢复副本仍需预览、核对并重新备份。").font(.footnote)
                if let failure { Text(failure).foregroundStyle(.red).font(.footnote) }
                if let message { Text(message).font(.footnote) }
            }
            Section("恢复方式") {
                Button("从外部工程包保留两份恢复") { importing = true }
                Button("校验上一版索引与全部登记素材") { Task { await inspectPrevious() } }.disabled(issue.projectID == nil)
                if let candidate { candidateSummary(candidate) }
            }
            Section("可另存的原始文件") {
                Text("文件存在不等于可播放或已恢复。缓存不列出；逐个保存副本，不移除原文件。Files 接收不代表云上传完成。").font(.footnote).foregroundStyle(.secondary)
                Button("重新读取文件列表") { Task { await refreshFiles() } }.disabled(!canBrowseFiles)
                ForEach(files, id: \.path) { file in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(file.path).font(.caption).textSelection(.enabled)
                        LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file)).font(.caption)
                        Button("保存副本到 Files") { Task { await saveFile(file) } }
                    }
                }
            }
        }
    }
    private func candidateSummary(_ candidate: IndexRecoveryCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(candidate.title).font(.headline)
            Text("上一版修订 \(candidate.revision) · \(candidate.takeCount) 个 Take · \(candidate.assetCount) 个登记素材已校验").font(.footnote).foregroundStyle(.secondary)
            Button("创建独立恢复副本") { confirm = true }
        }
    }
    private func refreshFiles() async {
        guard !blocked else { return }
        working = true; store.busy = true; stage = "正在读取原件…"
        defer { working = false; store.busy = false }
        do { files = try await store.repository.libraryIssueFiles(issue.directoryName); failure = nil }
        catch { failure = error.localizedDescription }
    }
    private func inspectPrevious() async {
        guard !blocked else { return }
        working = true; store.busy = true; stage = "正在校验上一版与素材…"; candidate = nil
        defer { working = false; store.busy = false }
        do { candidate = try await store.repository.inspectPreviousIndex(issue.directoryName); failure = nil }
        catch { failure = error.localizedDescription }
    }
    private func saveFile(_ file: ProjectFile) async {
        guard !blocked else { return }
        do { urls = [try await store.repository.libraryIssueFileURL(issue.directoryName, path: file.path)]; exporting = true }
        catch { failure = error.localizedDescription }
    }
    private func recover() async {
        guard !blocked, let candidate else { return }
        working = true; stage = "正在创建恢复副本…"; defer { working = false }
        do { try await store.recoverLibraryIssue(candidate); dismiss() }
        catch { self.candidate = nil; failure = error.localizedDescription }
    }
}

import SwiftUI
import CoverCore

@MainActor final class StudioBootstrap: ObservableObject {
    @Published private(set) var store: StudioStore?
    @Published private(set) var opening = false
    @Published private(set) var problem: String?
    @Published private(set) var pendingLog: PendingRestoreLog?
    private(set) var root: URL?
    private var imports: [(url: URL, access: Bool)] = []
    private var importing = false

    func open() async {
        guard !opening, store == nil else { return }
        opening = true; problem = nil; pendingLog = nil
        do {
            guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw StudioError("系统未提供本地应用目录，尚未创建或切换作品库。")
            }
            let base: URL
            if let root { base = root }
            else {
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("--startup-ui-fixture") { base = try await StartupUITestFixture.makeLibrary() }
                else { base = support.appendingPathComponent("MyCoverStudio/Projects", isDirectory: true) }
                #else
                base = support.appendingPathComponent("MyCoverStudio/Projects", isDirectory: true)
                #endif
                root = base
            }
            let repository = try await Task.detached(priority: .userInitiated) { try ProjectRepository(root: base) }.value
            let candidate = StudioStore(repository: repository)
            guard await candidate.load() else { throw StudioError(candidate.error ?? "作品库暂时无法读取。") }
            store = candidate
        } catch {
            problem = error.localizedDescription
            if let root { pendingLog = try? RepositoryStartup.pending(root: root) }
        }
        opening = false
        if store != nil { await importQueuedArchives() }
        else { releaseQueuedArchives() }
    }
    func openArchive(_ url: URL) async {
        imports.append((url, url.startAccessingSecurityScopedResource()))
        if store != nil { await importQueuedArchives() }
        else if !opening { await open() }
    }
    private func importQueuedArchives() async {
        guard !importing, let store else { return }
        importing = true; defer { importing = false }
        while !imports.isEmpty {
            let entry = imports.removeFirst()
            do { try await store.restore(entry.url, keepBoth: true) } catch { store.report(error) }
            if entry.access { entry.url.stopAccessingSecurityScopedResource() }
        }
    }
    private func releaseQueuedArchives() {
        guard !imports.isEmpty else { return }
        for entry in imports where entry.access { entry.url.stopAccessingSecurityScopedResource() }
        imports.removeAll()
        problem = (problem ?? "") + "\n\n尚未导入从 Files 打开的工程包。请先处理本地作品库，再重新选择原包；外部文件未修改。"
    }
    func preservePendingAndRetry() async {
        guard !opening, store == nil, let root, let expected = pendingLog else { return }
        opening = true
        do {
            _ = try await Task.detached(priority: .userInitiated) { try RepositoryStartup.preservePending(root: root, expected: expected) }.value
            opening = false; pendingLog = nil
            await open()
        } catch {
            problem = error.localizedDescription; pendingLog = try? RepositoryStartup.pending(root: root); opening = false
            releaseQueuedArchives()
        }
    }
}

struct StudioLaunchView: View {
    @ObservedObject var bootstrap: StudioBootstrap
    @State private var confirmPreservation = false
    @State private var logs = false
    var body: some View {
        Group {
            if let store = bootstrap.store {
                StudioRoot().environmentObject(store).task {
                    #if DEBUG
                    await MediaSmokeCheck.runIfRequested()
                    #endif
                }
            } else {
                NavigationStack { failureContent }
            }
        }
        .confirmationDialog("保留事务日志并重新打开？", isPresented: $confirmPreservation, titleVisibility: .visible) {
            Button("取消", role: .cancel) {}
            Button("保留日志，重试打开作品库") { Task { await bootstrap.preservePendingAndRetry() } }
        } message: {
            Text("仅停用并保留当前事务日志，工程与安全副本不移动、不删除。旧工程可能仍在存储页的安全副本中；打开作品库不代表该工程已恢复，请检查并另存原件或从外部包恢复。")
        }
        .sheet(isPresented: $logs) { if let root = bootstrap.root { NavigationStack { StartupLogsView(root: root) } } }
    }
    private var failureContent: some View {
        List {
            if bootstrap.opening || bootstrap.problem == nil {
                Section { ProgressView("正在打开本地作品库…") }
            } else {
                Section("本地作品库未能打开") {
                    Text(bootstrap.problem ?? "请重新检查本地目录。")
                    Text("未切换为空作品库，也未清空原目录。请勿卸载 App 或清理安全副本，以免失去尚未备份的原件。").font(.footnote).foregroundStyle(.secondary)
                    Button("重试打开") { Task { await bootstrap.open() } }
                }
                if let pending = bootstrap.pendingLog {
                    Section("待处理恢复事务") {
                        Text("日志 \(ByteCountFormatter.string(fromByteCount: pending.bytes, countStyle: .file))").font(.footnote)
                        Text("SHA-256：\(pending.sha256)").font(.caption).textSelection(.enabled)
                        Button("保留事务日志并重新打开…") { confirmPreservation = true }
                    }
                }
                if bootstrap.root != nil { Section { Button("查看已保留的启动日志") { logs = true } } }
            }
        }.navigationTitle("My Cover Studio")
    }
}

struct StartupLogsView: View {
    @Environment(\.dismiss) var dismiss
    let root: URL
    @State private var entries: [RetainedStartupLog] = []
    @State private var failure: String?
    @State private var loading = true
    @State private var exporting = false
    @State private var urls: [URL] = []
    var body: some View {
        List {
            Section {
                Text("这些日志记录曾停用的恢复事务，保留不等于工程已恢复。原工程和安全副本仍需核对；可另存日志，不自动删除。").font(.footnote).foregroundStyle(.secondary)
                if loading { ProgressView("正在读取日志…") }
                if let failure { Text(failure).foregroundStyle(.red).font(.footnote) }
                if !loading && entries.isEmpty && failure == nil { Text("没有保留的启动事务日志。") }
            }
            ForEach(entries) { entry in
                Section {
                    Text(entry.name).font(.caption).textSelection(.enabled)
                    LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))
                    Button("保存副本到 Files") {
                        do { urls = [try RepositoryStartup.retainedLogURL(entry.name, root: root)]; exporting = true }
                        catch { failure = error.localizedDescription }
                    }
                }
            }
        }.navigationTitle("启动恢复日志").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(isPresented: $exporting) { DocumentExportPicker(urls: urls) { _ in exporting = false } }
            .task {
                defer { loading = false }
                do { entries = try await Task.detached { try RepositoryStartup.retainedLogs(root: root) }.value }
                catch { failure = error.localizedDescription }
            }
    }
}

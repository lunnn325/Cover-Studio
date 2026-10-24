import SwiftUI
import CoverCore

struct LibraryView: View {
    @EnvironmentObject var store: StudioStore
    @State private var search = ""
    @State private var backup = false
    @State private var storage = false
    @State private var rename = false
    @State private var restorePicker = false
    @State private var recoverySheet = false
    @State private var recoveryPreview = false
    @State private var recoveryTakeID: UUID?
    @State private var pendingClosure: PendingRecording?
    @State private var closeRecovery = false
    @State private var damagedIssue: LibraryIssue?
    var filtered: [StudioProject] {
        store.projects.filter { search.isEmpty || ($0.song.title + " " + $0.song.artist + " " + $0.song.group).localizedCaseInsensitiveContains(search) }
    }
    var groups: [String: [StudioProject]] {
        Dictionary(grouping: filtered) { project in
            if !project.song.group.isEmpty { return project.song.group }
            return project.song.artist.isEmpty ? project.song.title : project.song.title + " · " + project.song.artist
        }
    }
    var body: some View {
        List {
            Section {
                Button { restorePicker = true } label: { Label("从工程包恢复 / 验证", systemImage: "square.and.arrow.down") }
                Button { storage = true } label: { Label("存储管理", systemImage: "internaldrive") }
            }
            issueSection
            if !store.pendingRecordings.isEmpty {
                Section("上次未完成的录制") {
                    ForEach(store.pendingRecordings) { pending in pendingRow(pending) }
                }
            }
            if filtered.isEmpty && store.libraryIssues.isEmpty { ContentUnavailableView(search.isEmpty ? "还没有作品" : "没有匹配的作品", systemImage: "square.stack", description: Text("导入伴奏开始录制，或从工程包恢复。")) }
            ForEach(groups.keys.sorted(), id: \.self) { group in
                Section(group) {
                    ForEach(groups[group] ?? []) { project in
                        Button { Task { await store.select(project.id) } } label: {
                            HStack(spacing: 14) {
                                cover(project)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(project.song.title).font(.headline).foregroundStyle(.primary)
                                    Text(project.archived ? "已归档 · 从外部恢复源素材" : "\(project.arrangements.count) 个伴奏版本 · \(project.takes.filter { !$0.isPractice }.count) 个 Take").font(.subheadline).foregroundStyle(.secondary)
                                    Text(project.modifiedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if store.selectedID == project.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                            }.padding(.vertical, 5)
                        }
                        .contextMenu {
                            Button("打开") { Task { await store.select(project.id) } }
                            Button("备份 / 恢复") { Task { await store.select(project.id); backup = true } }
                        }
                    }
                }
            }
            if let project = store.selected {
                Section("当前工程") {
                    Button("重命名与手动分组") { rename = true }.disabled(project.archived)
                    Button("复制工程尝试新版本") { Task { do { try await store.duplicate() } catch { store.report(error) } } }.disabled(project.archived)
                    Button("工程备份与恢复") { backup = true }
                    if !project.archived {
                        Picker("当前伴奏版本", selection: store.binding(\.arrangementID, fallback: project.arrangementID)) {
                            ForEach(project.arrangements) { arrangement in Text(arrangement.name).tag(arrangement.id) }
                        }
                        Text("切换伴奏版本不会修改已有 Take 绑定的伴奏和变调。").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }.searchable(text: $search, prompt: "歌曲、歌手或分组")
            .disabled(store.recording.isBusy)
            .sheet(isPresented: $backup) { NavigationStack { ArchiveView() } }
            .sheet(isPresented: $storage) { NavigationStack { StorageView() } }
            .sheet(isPresented: $rename) { NavigationStack { RenameProjectView() } }
            .sheet(item: $damagedIssue) { issue in NavigationStack { DamagedProjectView(issue: issue) } }
            .sheet(isPresented: $recoverySheet, onDismiss: { store.refreshPendingRecordings() }) {
                NavigationStack { RecordView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { recoverySheet = false }.disabled(store.recording.isBusy) } } }
                    .interactiveDismissDisabled(store.recording.isBusy)
            }
            .sheet(isPresented: $recoveryPreview) { NavigationStack { TakePreviewView(takeID: recoveryTakeID) } }
            .confirmationDialog("保留文件并结束此恢复记录？", isPresented: $closeRecovery, titleVisibility: .visible) {
                Button("取消", role: .cancel) {}
                Button("保留文件，结束接唱") {
                    guard let pendingClosure else { return }
                    Task { do { try await store.closePending(pendingClosure) } catch { store.report(error) } }
                }
            } message: { Text("不会重新打开麦克风。已有 Take 保留，未登记原件和日志纳入完整工程包，但不代表尾段已能播放或同步；精简包可能不含这些原件。") }
            .overlay { if store.busy { ProgressView("正在处理本地文件…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .onAppear { store.refreshPendingRecordings() }
            .fileImporter(isPresented: $restorePicker, allowedContentTypes: [.coverProject, .data]) { result in
                Task {
                    do { try await store.restore(try result.get(), keepBoth: true) } catch { store.report(error) }
                }
            }
    }
    @ViewBuilder private var issueSection: some View {
        if !store.libraryIssues.isEmpty {
            Section("需要恢复的工程目录") {
                Text("这些目录未被删除。可校验上一版索引创建副本、另存原件，或从外部工程包恢复。").font(.footnote).foregroundStyle(.secondary)
                ForEach(store.libraryIssues) { issue in
                    Button { damagedIssue = issue } label: {
                        Label(issue.directoryName, systemImage: "exclamationmark.folder").font(.caption).lineLimit(2)
                    }
                }
                Button("重新检查作品库") { Task { await store.refreshLibrary() } }
            }
        }
    }
    private func pendingRow(_ pending: PendingRecording) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pending.name).font(.headline)
            Text("已保存 \(pending.savedSegments) 个片段，未封装的尾段不能保证恢复。").font(.footnote).foregroundStyle(.secondary)
            if pending.savedSegments > 0 {
                Button("预览已保存片段") { Task { await store.select(pending.projectID); recoveryTakeID = pending.takeID; recoveryPreview = true } }
            }
            if pending.takeID != nil {
                Button("检查设备后接唱") { Task { await store.resumeRecording(pending); if store.recording.isBusy { recoverySheet = true } } }
            }
            Button("保留文件并结束接唱") { pendingClosure = pending; closeRecovery = true }
        }.disabled(store.exports.working || store.busy || store.auxiliaryRecording)
    }
    @ViewBuilder func cover(_ project: StudioProject) -> some View {
        if let id = project.song.coverAssetID, let asset = project.asset(id), let image = UIImage(contentsOfFile: store.repository.directory(project.id).appendingPathComponent(asset.path).path) {
            Image(uiImage: image).resizable().scaledToFill().frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
        } else if let image = UIImage(contentsOfFile: store.repository.directory(project.id).appendingPathComponent("thumbnail.jpg").path) {
            Image(uiImage: image).resizable().scaledToFill().frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Image(systemName: project.archived ? "archivebox" : "music.note").font(.title2).foregroundStyle(.secondary).frame(width: 48, height: 48).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct RenameProjectView: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) var dismiss
    var body: some View {
        Form {
            TextField("歌曲名", text: store.binding(\.song.title, fallback: ""))
            TextField("歌手", text: store.binding(\.song.artist, fallback: ""))
            TextField("自定义分组（留空自动归组）", text: store.binding(\.song.group, fallback: ""))
            Text("同名歌曲只在列表归组，工程与素材保持独立。").font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("整理作品").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { Task { do { try await store.flush(); dismiss() } catch { store.report(error) } } } } }
    }
}

struct StorageSummary {
    var source: Int64 = 0
    var exports: Int64 = 0
    var cache: Int64 = 0
    var retained: Int64 = 0
    var free: Int64 = 0
}

struct RetainedSnapshot: Identifiable {
    var id: String
    var title: String
    var bytes: Int64
    var hasIndex: Bool
}

struct StorageView: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) var dismiss
    @State private var summary = StorageSummary()
    @State private var pendingTake: Take?
    @State private var firstConfirm = false
    @State private var finalConfirm = false
    @State private var outputLibrary = false
    @State private var mediaRecovery = false
    @State private var clearCache = false
    @State private var snapshots: [RetainedSnapshot] = []
    @State private var pendingSnapshot: RetainedSnapshot?
    @State private var snapshotFirst = false
    @State private var snapshotFinal = false
    @State private var snapshotPackage: URL?
    @State private var exportingSnapshot = false
    @State private var snapshotPicker = false
    var project: StudioProject? { store.selected }
    var body: some View {
        takeProtectedContent
            .navigationTitle("存储管理").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { await refresh() }
            .sheet(isPresented: $outputLibrary, onDismiss: { Task { await refresh() } }) { NavigationStack { OutputLibraryView() } }
            .sheet(isPresented: $mediaRecovery, onDismiss: { Task { await refresh() } }) { NavigationStack { MediaRecoveryView() } }
            .interactiveDismissDisabled(exportingSnapshot)
            .sheet(isPresented: $snapshotPicker) {
                if let snapshotPackage { DocumentExportPicker(urls: [snapshotPackage]) { success in snapshotPicker = false; if success { store.notice = "安全副本已交给 Files，云上传仍未验证。可从作品库选择此包恢复。" } } }
            }
            .confirmationDialog("清理可重建缓存？", isPresented: $clearCache) {
                Button("取消", role: .cancel) {}
                Button("清理缓存") { Task { await cleanCache() } }
            }

    }
    private var takeProtectedContent: some View {
        snapshotProtectedContent
            .confirmationDialog("删除 \(pendingTake?.name ?? "Take")？", isPresented: $firstConfirm, titleVisibility: .visible) {
                Button("取消", role: .cancel) {}
                Button("继续查看影响", role: .destructive) { finalConfirm = true }
            } message: { Text("删除该 Take 的索引及仅由它使用的原始片段。共享或被其他 Take 使用的素材会保留。") }
            .alert("最终确认：永久删除 Take", isPresented: $finalConfirm) {
                Button("取消", role: .cancel) {}
                Button("确认删除", role: .destructive) { Task { await deleteTake() } }
            } message: { Text("此操作不可撤销。建议先创建完整工程备份。当前后期引用已受保护。") }
    }
    private var snapshotProtectedContent: some View {
        storageList
            .confirmationDialog("移除所选安全 / 恢复副本？", isPresented: $snapshotFirst, titleVisibility: .visible) {
                Button("取消", role: .cancel) {}
                Button("继续查看最终确认", role: .destructive) { snapshotFinal = true }
            } message: { Text("所选副本可能是旧版本录制的唯一来源。建议先校验并导出工程包，不能因新版本可打开就认为旧素材都已备份。") }
            .alert("最终确认：永久移除副本", isPresented: $snapshotFinal) {
                Button("取消", role: .cancel) {}
                Button("确认移除所选副本", role: .destructive) { Task { await removeSnapshot() } }
            } message: { Text("\(pendingSnapshot?.title ?? "") · \(bytes(pendingSnapshot?.bytes ?? 0))。此操作不可撤销，不会修改当前活动工程；所选副本的独有素材将永久移除。") }
    }
    private var storageList: some View {
        List {
            Section("整个作品库") {
                LabeledContent("源素材", value: bytes(summary.source))
                LabeledContent("导出与临时渲染", value: bytes(summary.exports))
                LabeledContent("可重建缓存", value: bytes(summary.cache))
                LabeledContent("安全副本 / 恢复暂存", value: bytes(summary.retained))
                LabeledContent("系统可用", value: bytes(summary.free))
                Text("不会自动删除原始素材。保留的安全副本可在下方导出工程包；只有明确两次确认才会移除所选副本。").font(.footnote).foregroundStyle(.secondary)
            }
            if !snapshots.isEmpty {
                Section("保留的安全 / 恢复副本") {
                    ForEach(snapshots) { snapshot in snapshotRow(snapshot) }
                    if exportingSnapshot { ProgressView("正在校验并生成副本工程包…") }
                }
            }
            if project != nil {
                Section("未登记 / 未引用原件") {
                    Button("检查并保留原件") { mediaRecovery = true }.disabled(store.exports.working)
                    Text("可能包含中断尾段或导入未完成的原件；不会自动删除或伪造可播放状态。").font(.footnote).foregroundStyle(.secondary)
                }
                Section("导出成品") {
                    Button("浏览全部成品与未登记文件") { outputLibrary = true }.disabled(store.exports.working)
                    Text("历史成品按文件保留；未登记输出单独标明，可预览、分享或两次确认后删除。").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let project, !project.archived {
                Section("当前工程的 Take") {
                    ForEach(project.takes) { take in takeRow(take, project: project) }
                }
                Section {
                    Button("清理当前工程的试听缓存") { clearCache = true }
                    Text("只清除 cache/ 中可重新生成的试听文件，不处理伴奏、Take 或已导出成品。").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func snapshotRow(_ snapshot: RetainedSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent(snapshot.title, value: bytes(snapshot.bytes))
            Text(snapshot.id.hasPrefix(".safety-") ? "替换前的旧工程，可能含独有录制。" : "失败复制 / 恢复的暂存内容，尚不能视为完整工程。").font(.footnote).foregroundStyle(.secondary)
            if snapshot.hasIndex { Button("校验并导出此副本为工程包") { Task { await exportSnapshot(snapshot) } }.disabled(exportingSnapshot) }
            Button("移除此副本…", role: .destructive) { pendingSnapshot = snapshot; snapshotFirst = true }.disabled(exportingSnapshot)
        }
    }
    private func takeRow(_ take: Take, project: StudioProject) -> some View {
        let locked = project.edit.selectedTakeID == take.id || project.edit.referencedTakeIDs.contains(take.id)
        let usedBytes = project.assets.filter { take.assetIDs.contains($0.id) }.reduce(Int64(0)) { $0 + $1.bytes }
        return VStack(alignment: .leading, spacing: 8) {
            LabeledContent(take.name, value: bytes(usedBytes))
            if locked { Text("当前编辑引用，不能删除；先选择其他 Take 或解除引用。").font(.footnote).foregroundStyle(.secondary) }
            else { Button("删除这个 Take…", role: .destructive) { pendingTake = take; firstConfirm = true } }
        }
    }
    func refresh() async {
        let root = store.repository.root
        summary = await Task.detached {
            var result = StorageSummary()
            result.free = (try? FileIntegrity.available(root)) ?? 0
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsPackageDescendants])
            while let file = enumerator?.nextObject() as? URL {
                guard let size = try? FileIntegrity.size(file) else { continue }
                let relative = String(file.path.dropFirst(root.path.count))
                if relative.contains("/.safety-") || relative.contains("/.replaced-") || relative.contains("/.restore-") || relative.contains("/.duplicate-") { result.retained += size }
                else if relative.contains("/media/") { result.source += size }
                else if relative.contains("/exports/") { result.exports += size }
                else if relative.contains("/cache/") { result.cache += size }
            }
            return result
        }.value
        snapshots = await Task.detached {
            let files = FileManager.default
            return ((try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []).compactMap { url -> RetainedSnapshot? in
                let name = url.lastPathComponent
                guard Self.validSnapshotName(name), let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory == true, values.isSymbolicLink != true else { return nil }
                let data = try? Data(contentsOf: url.appendingPathComponent("project.json"))
                let project = data.flatMap { try? JSONDecoder().decode(StudioProject.self, from: $0) }
                var size: Int64 = 0
                let contents = files.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
                while let child = contents?.nextObject() as? URL { size += (try? FileIntegrity.size(child)) ?? 0 }
                return RetainedSnapshot(id: name, title: project?.song.title ?? "未提交的恢复暂存", bytes: size, hasIndex: project != nil)
            }.sorted { $0.title < $1.title }
        }.value

    }
    nonisolated static func validSnapshotName(_ name: String) -> Bool {
        ProjectFiles.isRetainedDirectory(name)
    }
    func snapshotDirectory(_ name: String) throws -> URL {
        let root = store.repository.root.resolvingSymlinksInPath()
        let direct = root.appendingPathComponent(name), resolved = direct.resolvingSymlinksInPath()
        guard Self.validSnapshotName(name), direct.path == resolved.path, resolved.path.hasPrefix(root.path + "/") else { throw StudioError("副本目录不在受控范围，已停止操作。") }
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(".restore-transaction.json").path) else { throw StudioError("存在待恢复的替换事务，请重启 App 完成恢复后再处理副本。") }
        return resolved
    }
    func exportSnapshot(_ snapshot: RetainedSnapshot) async {
        guard !store.busy, !store.recording.isBusy else { return }
        exportingSnapshot = true; store.busy = true; defer { exportingSnapshot = false; store.busy = false }
        do {
            let directory = try snapshotDirectory(snapshot.id)
            let original = try JSONDecoder().decode(StudioProject.self, from: Data(contentsOf: directory.appendingPathComponent("project.json")))
            let project = try await Task.detached { try ProjectFiles.adoptingUnregistered(original, root: directory) }.value
            let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".coverproject")
            try await Task.detached(priority: .userInitiated) { try ProjectArchive.create(project: project, root: directory, destination: output, mode: .full, includeExports: true) }.value
            snapshotPackage = output; snapshotPicker = true
        } catch { store.report(error) }
    }
    func removeSnapshot() async {
        guard let snapshot = pendingSnapshot, !store.busy, !store.recording.isBusy else { return }
        do {
            let directory = try snapshotDirectory(snapshot.id)
            try FileManager.default.removeItem(at: directory)
            pendingSnapshot = nil; await refresh()
        } catch { store.report(error) }
    }
    func deleteTake() async {
        guard let take = pendingTake, let project, !store.recording.isBusy else { return }
        do {
            guard project.edit.selectedTakeID != take.id, !project.edit.referencedTakeIDs.contains(take.id) else { throw StudioError("Take 已被编辑引用，已阻止删除。") }
            var referenced = project.arrangements.reduce(into: Set<UUID>()) { $0.formUnion($1.assetIDs) }
            project.takes.filter { $0.id != take.id }.forEach { referenced.formUnion($0.assetIDs) }
            referenced.formUnion([project.edit.visualAssetID, project.song.coverAssetID].compactMap { $0 })
            let removable = project.assets.filter { take.assetIDs.contains($0.id) && !referenced.contains($0.id) }
            store.update {
                $0.takes.removeAll { $0.id == take.id }; $0.assets.removeAll { asset in removable.contains { $0.id == asset.id } }
                for i in $0.takes.indices where $0.takes[i].promotedTakeID == take.id { $0.takes[i].promotedTakeID = nil }
            }
            try await store.flush()
            let root = store.repository.directory(project.id).resolvingSymlinksInPath()
            for asset in removable {
                let target = root.appendingPathComponent(asset.path).resolvingSymlinksInPath()
                guard ProjectRules.safePath(asset.path), target.path.hasPrefix(root.path + "/") else { throw StudioError("删除路径无效，已停止。") }
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            }
            pendingTake = nil; await refresh()
        } catch { store.report(error) }
    }
    func cleanCache() async {
        guard let project, !store.exports.working, !store.recording.isBusy else { return }
        do {
            let root = store.repository.directory(project.id).resolvingSymlinksInPath()
            let cache = root.appendingPathComponent("cache").resolvingSymlinksInPath()
            guard cache.path.hasPrefix(root.path + "/") else { throw StudioError("缓存目录无效。") }
            if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
            await refresh()
        } catch { store.report(error) }
    }

}

struct SettingsView: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) var dismiss
    var body: some View {
        List {
            Section("录制") {
                Text("默认倒数 3 秒；默认关闭人声耳返。每次正式录制前确认真实输入与伴奏输出。")
                Text("AirPods 高质量能力由系统报告。未启用时可选择普通蓝牙模式或设备麦克风。蓝牙音质和音画同步尚需实机验证。").font(.footnote).foregroundStyle(.secondary)
                Button("打开摄像头 / 麦克风权限设置") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            }
            Section("高级能力") {
                Label("AI 分离：尚未集成本地模型", systemImage: "minus.circle")
                Label("自动歌词对齐 / 逐字：未开放", systemImage: "minus.circle")
                Label("自动修音：未开放，保持原声", systemImage: "minus.circle")
                Label("智能拼接：使用手动切点", systemImage: "minus.circle")
                Label("4K：未通过管线验证，暂不开放", systemImage: "minus.circle")
                Text(UnavailableAI().capability.explanation).font(.footnote).foregroundStyle(.secondary)
            }
            Section("隐私与工程") {
                Text("本地优先，无账号、无遥测、不上传音视频。Google Drive 通过系统 Files 选择，不内置登录。")
                Text("iPhone 和 iPad 各自编辑，通过 .coverproject 包手动迁移。Files 接收文件不能证明远端上传完成。")
                LabeledContent("最低系统", value: "iOS / iPadOS 17")
                LabeledContent("工程格式", value: "COVERP01 / schema 1")
                LabeledContent("外观", value: "跟随系统")
            }
        }.navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
}

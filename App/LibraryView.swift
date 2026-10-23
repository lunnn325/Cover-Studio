import SwiftUI
import CoverCore

struct LibraryView: View {
    @EnvironmentObject var store: StudioStore
    @State private var search = ""
    @State private var backup = false
    @State private var storage = false
    @State private var rename = false
    @State private var restorePicker = false
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
            if filtered.isEmpty { ContentUnavailableView(search.isEmpty ? "还没有作品" : "没有匹配的作品", systemImage: "square.stack", description: Text("导入伴奏开始录制，或从工程包恢复。")) }
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
            .fileImporter(isPresented: $restorePicker, allowedContentTypes: [.coverProject, .data]) { result in
                Task {
                    do { try await store.restore(try result.get(), keepBoth: true) } catch { store.report(error) }
                }
            }
    }
    @ViewBuilder func cover(_ project: StudioProject) -> some View {
        if let id = project.song.coverAssetID, let asset = project.asset(id), let image = UIImage(contentsOfFile: store.repository.directory(project.id).appendingPathComponent(asset.path).path) {
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

struct StorageView: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) var dismiss
    @State private var summary = StorageSummary()
    @State private var pendingTake: Take?
    @State private var firstConfirm = false
    @State private var finalConfirm = false
    @State private var clearCache = false
    @State private var outputJobs: [ExportJob] = []
    @State private var pendingOutput: ExportJob?
    @State private var outputFirst = false
    @State private var outputFinal = false
    var project: StudioProject? { store.selected }
    var body: some View {
        List {
            Section("整个作品库") {
                LabeledContent("源素材", value: bytes(summary.source))
                LabeledContent("导出与临时渲染", value: bytes(summary.exports))
                LabeledContent("可重建缓存", value: bytes(summary.cache))
                LabeledContent("安全副本 / 恢复暂存", value: bytes(summary.retained))
                LabeledContent("系统可用", value: bytes(summary.free))
                Text("不会自动删除原始素材。安全副本与失败恢复暂存保留在 App 文件目录；确认数据安全后可通过 Files 人工处理。").font(.footnote).foregroundStyle(.secondary)
            }
            if let project, !project.archived {
                Section("当前工程的 Take") {
                    ForEach(project.takes) { take in
                        let locked = project.edit.selectedTakeID == take.id || project.edit.referencedTakeIDs.contains(take.id)
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent(take.name, value: bytes(project.assets.filter { take.assetIDs.contains($0.id) }.reduce(0) { $0 + $1.bytes }))
                            if locked { Text("当前编辑引用，不能删除；先选择其他 Take 或解除引用。").font(.footnote).foregroundStyle(.secondary) }
                            else { Button("删除这个 Take…", role: .destructive) { pendingTake = take; firstConfirm = true } }
                        }
                    }
                }
                Section("已导出成品") {
                    ForEach(outputJobs.filter { $0.status == "完成" }) { job in
                        HStack { Text(job.variant.label); Spacer(); Button("删除…", role: .destructive) { pendingOutput = job; outputFirst = true } }
                    }
                    Text("删除成品不会删除录制原件；仍可从工程重新导出。").font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("清理当前工程的试听缓存") { clearCache = true }
                    Text("只清除 cache/ 中可重新生成的试听文件，不处理伴奏、Take 或已导出成品。").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }.navigationTitle("存储管理").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { await refresh() }
            .confirmationDialog("删除 \(pendingTake?.name ?? "Take")？", isPresented: $firstConfirm, titleVisibility: .visible) {
                Button("取消", role: .cancel) {}
                Button("继续查看影响", role: .destructive) { finalConfirm = true }
            } message: { Text("删除该 Take 的索引及仅由它使用的原始片段。共享或被其他 Take 使用的素材会保留。") }
            .alert("最终确认：永久删除 Take", isPresented: $finalConfirm) {
                Button("取消", role: .cancel) {}
                Button("确认删除", role: .destructive) { Task { await deleteTake() } }
            } message: { Text("此操作不可撤销。建议先创建完整工程备份。当前后期引用已受保护。") }
            .confirmationDialog("清理可重建缓存？", isPresented: $clearCache) {
                Button("取消", role: .cancel) {}
                Button("清理缓存") { Task { await cleanCache() } }
            }
            .confirmationDialog("删除所选导出成品？", isPresented: $outputFirst, titleVisibility: .visible) {
                Button("取消", role: .cancel) {}
                Button("继续", role: .destructive) { outputFinal = true }
            }
            .alert("最终确认：删除导出成品", isPresented: $outputFinal) {
                Button("取消", role: .cancel) {}
                Button("确认删除", role: .destructive) { Task { await deleteOutput() } }
            } message: { Text("只删除所选成品，不删除伴奏、人声和画面原件。") }
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
                if relative.contains("/.safety-") || relative.contains("/.replaced-") || relative.contains("/.restore-") { result.retained += size }
                else if relative.contains("/media/") { result.source += size }
                else if relative.contains("/exports/") { result.exports += size }
                else if relative.contains("/cache/") { result.cache += size }
            }
            return result
        }.value
        if let project {
            if let data = try? Data(contentsOf: store.repository.directory(project.id).appendingPathComponent("exports/queue.json")), let jobs = try? JSONDecoder().decode([ExportJob].self, from: data) { outputJobs = jobs }
            else { outputJobs = ExportService.restoredJobs(assets: project.assets) }
        }
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
    func deleteOutput() async {
        guard let job = pendingOutput, let project, let path = job.path, !store.exports.working else { return }
        do {
            let root = store.repository.directory(project.id).resolvingSymlinksInPath()
            let target = root.appendingPathComponent(path).resolvingSymlinksInPath()
            guard ProjectRules.safePath(path), path.hasPrefix("exports/"), target.path.hasPrefix(root.path + "/exports/") else { throw StudioError("成品路径无效，已阻止删除。") }
            try FileManager.default.removeItem(at: target)
            if let asset = project.assets.first(where: { $0.path == path && $0.role == .export }) {
                store.update { $0.assets.removeAll { $0.id == asset.id } }; try await store.flush()
            }
            if let i = outputJobs.firstIndex(where: { $0.id == job.id }) { outputJobs[i].status = "已删除"; outputJobs[i].path = nil }
            try FileIntegrity.encoder().encode(outputJobs).write(to: root.appendingPathComponent("exports/queue.json"), options: .atomic)
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

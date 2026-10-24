import SwiftUI
import CoverCore

struct ArchiveView: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) var dismiss
    @State private var mode: BackupMode = .full
    @State private var chosenTakes = Set<UUID>()
    @State private var includeOutputs = false
    @State private var knownOutputs: [ExportedFile] = []
    @State private var chosenOutputs = Set<String>()
    @State private var outputReadError: String?
    @State private var loadingOutputs = true
    @State private var outputScopeID: UUID?
    @State private var packageURL: URL?
    @State private var archiveID: UUID?
    @State private var packageRevision: Int?
    @State private var packageProjectID: UUID?
    @State private var scopeNote = ""
    @State private var picker = false
    @State private var importing = false
    @State private var preparing = false
    @State private var releaseFirst = false
    @State private var releaseFinal = false
    @State private var releaseRevision: Int?
    @State private var pendingRestoreURL: URL?
    @State private var restoreChoice = false
    var project: StudioProject? { store.selected }
    private var archiveForm: some View {
        Form {
            if let project {
                Section {
                    Text(project.song.title).font(.headline)
                    Text(project.archived ? BackupLevel.archivedIndexOnly.label : project.backups.last?.level.label ?? BackupLevel.activeLocal.label).font(.subheadline).foregroundStyle(.secondary)
                    Text("Files 导出成功 ≠ Google Drive 已完成上传 ≠ 已验证可恢复。").font(.footnote).foregroundStyle(.orange)
                }
                if !project.archived {
                    Section("工程包内容") {
                        Picker("备份类型", selection: $mode) { ForEach(BackupMode.allCases, id: \.self) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                        if mode == .custom {
                            ForEach(project.takes) { take in takeChoice(take, project: project) }
                        }
                        if mode != .slim { Toggle("包含已完成的导出成品", isOn: $includeOutputs) }
                        if includeOutputs && mode != .slim { Text("包含当前和历史已完成成品；未登记或可能未完成的文件不在此包内，可从成品目录单独保存到 Files。").font(.footnote).foregroundStyle(.secondary) }
                        if includeOutputs && mode == .custom { outputChoices }
                        Text(mode == .full ? "完整：全部伴奏版本、Take、练习、歌词与编辑。默认省略可重新生成的导出成品。" : "精简 / 自定义：自动补齐当前编辑所需的 Take、旧片段、伴奏和照片，不能移除依赖素材。").font(.footnote).foregroundStyle(.secondary)
                        LabeledContent("源素材总计", value: bytes(project.assets.filter { $0.role != .export }.reduce(0) { $0 + $1.bytes }))
                        Button("生成并校验工程包") { Task { await prepare() } }.disabled(preparing || (includeOutputs && mode == .custom && (loadingOutputs || outputScopeID != project.id)))
                        if preparing { ProgressView("正在流式打包并重新读取校验…") }
                        if packageURL != nil {
                            Button("保存到 Files / Google Drive") { picker = true }.disabled(preparing || packageRevision != project.revision || packageProjectID != project.id)
                            if packageRevision != project.revision { Text("工程已修改，请重新打包后导出。").font(.footnote).foregroundStyle(.orange) }
                        }
                    }.disabled(preparing)
                    if canRelease {
                        releaseSection(project)
                    }
                }
            }
            Section("恢复与验证") {
                Button("选择外部工程包恢复 / 验证") { importing = true }.disabled(preparing)
                Text("校验全部哈希、长度和依赖后才恢复。同 ID 可保留两份或先留安全副本再替换。云文件不可用或空间不足会明确失败。").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
    var body: some View {
        archiveForm.navigationTitle("工程备份与恢复").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(preparing) } }
            .interactiveDismissDisabled(preparing)
            .task(id: project?.id) { await loadOutputs() }
            .onChange(of: mode) { _, _ in invalidatePackage() }
            .onChange(of: includeOutputs) { _, _ in if mode != .slim { invalidatePackage() } }
            .onChange(of: chosenTakes) { _, _ in if mode == .custom { invalidatePackage() } }
            .onChange(of: chosenOutputs) { _, _ in if mode == .custom && includeOutputs { invalidatePackage() } }
            .onChange(of: project?.id) { _, _ in invalidatePackage() }
            .sheet(isPresented: $picker) {
                if let packageURL { DocumentExportPicker(urls: [packageURL]) { success in
                    picker = false
                    guard success, let id = packageProjectID, let archiveID, let packageRevision else { return }
                    Task {
                        do { try await store.recordBackup(.init(archiveID: archiveID, revision: packageRevision, level: .exportedToProvider, note: scopeNote + " 系统 Files 已接收导出，远端上传状态未知。"), projectID: id) }
                        catch { store.report(error) }
                    }
                } }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.coverProject, .data]) { result in
                do { pendingRestoreURL = try result.get(); restoreChoice = true } catch { store.report(error) }
            }
            .confirmationDialog("恢复方式", isPresented: $restoreChoice, titleVisibility: .visible) {
                Button("取消", role: .cancel) { pendingRestoreURL = nil }
                Button("保留两份（默认安全副本）") { restore(keepBoth: true) }
                Button("同 ID 时保留旧工程安全副本再替换") { restore(keepBoth: false) }
            } message: { Text("包会先完整验证。替换时旧工程保留在安全目录，失败会回滚；没有同 ID 工程时直接导入。") }
            .confirmationDialog("释放本地源素材？", isPresented: $releaseFirst, titleVisibility: .visible) {
                Button("取消", role: .cancel) {}
                Button("继续查看最终确认", role: .destructive) { releaseFinal = true }
            } message: { Text("外部文件若未上传、被删除或不可读取，可能无法找回本地源素材。请确认已检查备份。") }
            .alert("最终确认：移除本地源素材", isPresented: $releaseFinal) {
                Button("取消", role: .cancel) {}
                Button("确认释放", role: .destructive) {
                    Task {
                        do {
                            guard releaseRevision == project?.revision else { throw StudioError("工程已修改，请重新备份后确认。") }
                            try await store.releaseSelected()
                        } catch { store.report(error) }
                    }
                }
            } message: { Text("当前备份验证级别：\(project?.backups.last?.level.label ?? "未知")。\(project?.backups.last(where: { $0.revision == project?.revision })?.note ?? "") 本地原始人声、视频与伴奏将移除；若备份排除了旧 Take，那些录制无法从此包恢复。作品占位与备份记录保留。") }
    }
    var canRelease: Bool {
        guard let project else { return false }
        return project.backups.contains { $0.revision == project.revision && ($0.level == .exportedToProvider || $0.level == .restoreVerified) }
    }
    private func takeChoice(_ take: Take, project: StudioProject) -> some View {
        let required: Bool = project.edit.selectedTakeID == take.id || project.edit.referencedTakeIDs.contains(take.id)
        let title = take.name + (required ? "（当前编辑必需）" : "")
        let selection = Binding<Bool>(get: { required || chosenTakes.contains(take.id) }, set: { selected in
            if selected { chosenTakes.insert(take.id) } else { chosenTakes.remove(take.id) }
        })
        return Toggle(title, isOn: selection).disabled(required)
    }
    private func releaseSection(_ project: StudioProject) -> some View {
        let sources = project.assets.filter { $0.role != .export }
        let total = sources.reduce(Int64(0)) { $0 + $1.bytes }
        return Section("释放本地空间") {
            Text("将移除本工程列出的 \(sources.count) 个源文件（\(bytes(total))），保留作品标题和备份记录。其他工程不会受影响。").font(.footnote)
            Text("已导出成品会保留，可到成品目录单独确认删除。").font(.footnote).foregroundStyle(.secondary)
            Text("当前状态：\(project.backups.last?.level.label ?? "未验证")。建议先从外部重新选择工程包，验证恢复后再释放。").font(.footnote).foregroundStyle(.orange)
            Text(project.backups.last(where: { $0.revision == project.revision })?.note ?? "").font(.footnote).foregroundStyle(.orange)
            Button("释放本地源素材…", role: .destructive) { releaseRevision = project.revision; releaseFirst = true }
        }
    }
    private var requiredOutputPaths: Set<String> {
        guard let project, let plan = try? ProjectRules.backupProject(project, mode: .custom, selected: chosenTakes) else { return [] }
        return Set(plan.assets.filter { $0.role == .export }.map { $0.path.precomposedStringWithCanonicalMapping.lowercased() })
    }
    @ViewBuilder private var outputChoices: some View {
        if loadingOutputs { ProgressView("正在读取可选成品…") }
        if let outputReadError { Text(outputReadError).font(.footnote).foregroundStyle(.orange) }
        ForEach(knownOutputs) { output in outputChoice(output) }
        if !loadingOutputs && knownOutputs.isEmpty && outputReadError == nil { Text("当前没有已登记的完成成品。").font(.footnote).foregroundStyle(.secondary) }
    }
    private func outputChoice(_ output: ExportedFile) -> some View {
        let required = requiredOutputPaths.contains(output.path.precomposedStringWithCanonicalMapping.lowercased())
        let title = output.name + (required ? "（编辑必需）" : "")
        let selection = Binding<Bool>(get: { required || chosenOutputs.contains(output.path) }, set: { selected in
            if selected { chosenOutputs.insert(output.path) } else { chosenOutputs.remove(output.path) }
        })
        return Toggle(title, isOn: selection).disabled(required)
    }
    private func loadOutputs() async {
        guard let project else { return }
        loadingOutputs = true; defer { loadingOutputs = false }
        outputScopeID = nil; knownOutputs = []; chosenOutputs = []
        let root = store.repository.directory(project.id)
        do {
            let outputs = try await Task.detached { try ExportCatalog.outputs(root: root, assets: project.assets).filter(\.completed) }.value
            guard !Task.isCancelled, self.project?.id == project.id else { return }
            knownOutputs = outputs; chosenOutputs = Set(outputs.map(\.path)); outputScopeID = project.id; outputReadError = nil
        } catch { knownOutputs = []; chosenOutputs = []; outputReadError = "成品记录无法读取。可取消包含成品，先备份原始素材。" }
    }
    private func invalidatePackage() {
        packageURL = nil; archiveID = nil; packageRevision = nil; packageProjectID = nil
    }
    func restore(keepBoth: Bool) {
        guard let url = pendingRestoreURL else { return }
        Task {
            preparing = true; defer { preparing = false; pendingRestoreURL = nil }
            do { try await store.restore(url, keepBoth: keepBoth) } catch { store.report(error) }
        }
    }
    func prepare() async {
        guard var project else { return }
        guard !(mode == .custom && includeOutputs) || (!loadingOutputs && outputScopeID == project.id) else {
            store.error = "请等当前工程的成品目录读取完成，或取消包含成品后先备份原始素材。"; return
        }
        preparing = true; store.busy = true; defer { preparing = false; store.busy = false }
        do {
            try await store.flush()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CoverArchives", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if includeOutputs && mode != .slim {
                let root = store.repository.directory(project.id)
                do {
                    let paths = Set(try ExportCatalog.outputs(root: root, assets: project.assets).filter(\.completed).map(\.path))
                    let outputAssets = try await Task.detached(priority: .userInitiated) {
                        try paths.map { path -> MediaAsset in
                            guard ProjectRules.safePath(path), path.hasPrefix("exports/") else { throw StudioError("导出文件路径无效。") }
                            let url = root.appendingPathComponent(path)
                            return try MediaAsset(path: path, role: .export, bytes: FileIntegrity.size(url), sha256: FileIntegrity.sha256(url))
                        }
                    }.value
                    let existingPaths = Set(project.assets.map { $0.path.precomposedStringWithCanonicalMapping.lowercased() })
                    project.assets.append(contentsOf: outputAssets.filter { !existingPaths.contains($0.path.precomposedStringWithCanonicalMapping.lowercased()) })
                }
            }
            let output = directory.appendingPathComponent(UUID().uuidString + ".coverproject")
            let selectedOutputs: Set<String>? = mode == .custom && includeOutputs ? chosenOutputs : nil
            let manifest = try await store.repository.backup(project, mode: mode, selected: chosenTakes, to: output, includeExports: includeOutputs,
                                                             selectedExportPaths: selectedOutputs)
            packageURL = output; archiveID = manifest.archiveID; packageRevision = project.revision; packageProjectID = project.id
            let kept = Set(manifest.project.takes.map(\.id))
            let excluded = project.takes.filter { !kept.contains($0.id) }.map(\.name)
            scopeNote = "\(mode.label)包包含 \(manifest.project.takes.count) 个 Take。" + (excluded.isEmpty ? "包含本地全部 Take。" : "未包含：" + excluded.joined(separator: "、") + "。释放本地素材后，这些 Take 无法从此包恢复。")
            scopeNote += " 已包含 \(manifest.project.assets.filter { $0.role == .export }.count) 个导出成品，未登记文件未包含。"
            try await store.recordBackup(.init(archiveID: manifest.archiveID, revision: project.revision, level: .archivePrepared, note: scopeNote + " 仅本地工程包已校验，尚未交给文件提供者。"), projectID: project.id)
        } catch { store.report(error) }
    }
}

func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }

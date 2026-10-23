import SwiftUI
import CoverCore

struct ArchiveView: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) var dismiss
    @State private var mode: BackupMode = .full
    @State private var chosenTakes = Set<UUID>()
    @State private var includeOutputs = false
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
    var project: StudioProject? { store.selected }
    var body: some View {
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
                            ForEach(project.takes) { take in
                                let required = project.edit.selectedTakeID == take.id || project.edit.referencedTakeIDs.contains(take.id)
                                Toggle(take.name + (required ? "（当前编辑必需）" : ""), isOn: Binding(get: { required || chosenTakes.contains(take.id) }, set: { value in if value { chosenTakes.insert(take.id) } else { chosenTakes.remove(take.id) } })).disabled(required)
                            }
                        }
                        if mode != .slim { Toggle("包含已完成的导出成品", isOn: $includeOutputs) }
                        Text(mode == .full ? "完整：全部伴奏版本、Take、练习、歌词与编辑。默认省略可重新生成的导出成品。" : "精简 / 自定义：自动补齐当前编辑所需的 Take、旧片段、伴奏和照片，不能移除依赖素材。").font(.footnote).foregroundStyle(.secondary)
                        LabeledContent("源素材总计", value: bytes(project.assets.reduce(0) { $0 + $1.bytes }))
                        Button("生成并校验工程包") { Task { await prepare() } }.disabled(preparing)
                        if preparing { ProgressView("正在流式打包并重新读取校验…") }
                        if packageURL != nil {
                            Button("保存到 Files / Google Drive") { picker = true }.disabled(preparing || packageRevision != project.revision || packageProjectID != project.id)
                            if packageRevision != project.revision { Text("工程已修改，请重新打包后导出。").font(.footnote).foregroundStyle(.orange) }
                        }
                    }.disabled(preparing)
                    if canRelease {
                        Section("释放本地空间") {
                            Text("将移除本工程列出的 \(project.assets.count) 个源文件（\(bytes(project.assets.reduce(0) { $0 + $1.bytes }))），保留作品标题和备份记录。其他工程不会受影响。").font(.footnote)
                            Text("当前状态：\(project.backups.last?.level.label ?? "未验证")。建议先从外部重新选择工程包，验证恢复后再释放。").font(.footnote).foregroundStyle(.orange)
                            Text(project.backups.last(where: { $0.revision == project.revision })?.note ?? "").font(.footnote).foregroundStyle(.orange)
                            Button("释放本地源素材…", role: .destructive) { releaseRevision = project.revision; releaseFirst = true }
                        }
                    }
                }
            }
            Section("恢复与验证") {
                Button("从外部工程包恢复安全副本") { importing = true }.disabled(preparing)
                Text("校验全部哈希、长度和依赖后才恢复。同 ID 工程默认保留两份，现有修改不会覆盖。云文件不可用或空间不足会明确失败。").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("工程备份与恢复").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(preparing) } }
            .interactiveDismissDisabled(preparing)
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
                Task {
                    preparing = true; defer { preparing = false }
                    do { try await store.restore(try result.get(), keepBoth: true) } catch { store.report(error) }
                }
            }
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
    func prepare() async {
        guard var project else { return }
        preparing = true; store.busy = true; defer { preparing = false; store.busy = false }
        do {
            try await store.flush()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CoverArchives", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if includeOutputs && mode != .slim {
                let root = store.repository.directory(project.id)
                if let data = try? Data(contentsOf: root.appendingPathComponent("exports/queue.json")), let jobs = try? JSONDecoder().decode([ExportJob].self, from: data) {
                    let paths = Set(jobs.filter { $0.status == "完成" }.compactMap(\.path))
                    let outputAssets = try await Task.detached(priority: .userInitiated) {
                        try paths.map { path -> MediaAsset in
                            guard ProjectRules.safePath(path), path.hasPrefix("exports/") else { throw StudioError("导出文件路径无效。") }
                            let url = root.appendingPathComponent(path)
                            return try MediaAsset(path: path, role: .export, bytes: FileIntegrity.size(url), sha256: FileIntegrity.sha256(url))
                        }
                    }.value
                    project.assets.append(contentsOf: outputAssets)
                }
            }
            let output = directory.appendingPathComponent(UUID().uuidString + ".coverproject")
            let manifest = try await store.repository.backup(project, mode: mode, selected: chosenTakes, to: output, includeExports: includeOutputs)
            packageURL = output; archiveID = manifest.archiveID; packageRevision = project.revision; packageProjectID = project.id
            let kept = Set(manifest.project.takes.map(\.id))
            let excluded = project.takes.filter { !kept.contains($0.id) }.map(\.name)
            scopeNote = "\(mode.label)包包含 \(manifest.project.takes.count) 个 Take。" + (excluded.isEmpty ? "包含本地全部 Take。" : "未包含：" + excluded.joined(separator: "、") + "。释放本地素材后，这些 Take 无法从此包恢复。")
            try await store.recordBackup(.init(archiveID: manifest.archiveID, revision: project.revision, level: .archivePrepared, note: scopeNote + " 仅本地工程包已校验，尚未交给文件提供者。"), projectID: project.id)
        } catch { store.report(error) }
    }
}

func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }

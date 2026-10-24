import SwiftUI
import AVFoundation
import CoverCore

struct PendingRecording: Identifiable {
    var id: UUID { takeID }
    var projectID: UUID
    var takeID: UUID
    var name: String
    var savedSegments: Int
}

@MainActor final class StudioStore: ObservableObject {
    @Published var projects: [StudioProject] = []
    @Published var selectedID: UUID? {
        didSet { if let selectedID { UserDefaults.standard.set(selectedID.uuidString, forKey: "lastProject") } }
    }
    @Published var error: String?
    @Published var notice: String?
    @Published var busy = false
    @Published var auxiliaryRecording = false
    @Published var pendingRecordings: [PendingRecording] = []
    let repository: ProjectRepository
    let playback = PlaybackEngine()
    let recording: RecordingCoordinator
    let exports = ExportService()
    private var loadedArrangement: UUID?
    private var saveTask: Task<Void, Never>?
    private var undoEdits: [UUID: [EditGraph]] = [:]
    var canUndoEdit: Bool { selectedID.flatMap { undoEdits[$0]?.isEmpty == false } ?? false }
    var selected: StudioProject? { projects.first { $0.id == selectedID } }
    var deviceID: String {
        if let value = UserDefaults.standard.string(forKey: "deviceID") { return value }
        let value = UUID().uuidString; UserDefaults.standard.set(value, forKey: "deviceID"); return value
    }
    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MyCoverStudio/Projects", isDirectory: true)
        do { repository = try ProjectRepository(root: base) }
        catch { fatalError("Cannot open local application support: \(error)") }
        recording = RecordingCoordinator(playback: playback, repository: repository)
        recording.store = self
    }
    func load() async {
        do {
            projects = try await repository.loadAll()
            let last = UserDefaults.standard.string(forKey: "lastProject").flatMap(UUID.init(uuidString:))
            selectedID = projects.first(where: { $0.id == last })?.id ?? projects.first?.id
            recording.video = selected?.recordVideo ?? true
            refreshPendingRecordings()
            if !pendingRecordings.isEmpty { notice = "发现上次中断的录制，可在作品库预览已保存片段，或检查路由后接唱。最后未封装片段可能无法播放，原文件仍保留。" }
        } catch { self.error = "作品库读取失败，原文件未修改。\(error.localizedDescription)" }
    }
    func report(_ error: Error) { self.error = error.localizedDescription }
    func refreshPendingRecordings() {
        pendingRecordings = projects.filter { !$0.archived }.compactMap { project in
            let url = repository.directory(project.id).appendingPathComponent("recording.json")
            guard let data = try? Data(contentsOf: url), let journal = try? JSONDecoder().decode(Take.self, from: data),
                  let take = project.takes.first(where: { $0.id == journal.id }) else { return nil }
            return PendingRecording(projectID: project.id, takeID: take.id, name: project.song.title + " · " + take.name, savedSegments: take.segments.count)
        }
    }
    func resumeRecording(_ pending: PendingRecording) async {
        guard !recording.isBusy, !auxiliaryRecording, !busy, !exports.working else { error = "请先结束当前操作。"; return }
        await select(pending.projectID)
        guard selectedID == pending.projectID else { return }
        await recording.preflight(recovering: pending.takeID)
    }
    func update(_ mutate: (inout StudioProject) -> Void) {
        guard let id = selectedID, let index = projects.firstIndex(where: { $0.id == id }), !projects[index].archived else { return }
        let previous = projects[index]
        mutate(&projects[index])
        if previous.edit != projects[index].edit {
            undoEdits[id, default: []].append(previous.edit)
            if undoEdits[id]!.count > 40 { undoEdits[id]!.removeFirst() }
        }
        if previous.exportPreset != projects[index].exportPreset, let data = try? FileIntegrity.encoder().encode(projects[index].exportPreset) {
            UserDefaults.standard.set(data, forKey: "defaultExportPreset")
        }
        projects[index].touch()
        let project = projects[index]
        saveTask?.cancel()
        saveTask = Task {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                try await repository.save(project)
            } catch is CancellationError {} catch { report(error) }
        }
    }
    func undoEdit() {
        guard !recording.isBusy, !auxiliaryRecording, !exports.working, let id = selectedID,
              let index = projects.firstIndex(where: { $0.id == id }) else { return }
        while let previous = undoEdits[id]?.popLast() {
            var candidate = projects[index]; candidate.edit = previous
            guard (try? ProjectRules.validate(candidate)) != nil else { continue }
            candidate.touch(); projects[index] = candidate
            Task { do { try await flush() } catch { report(error) } }
            return
        }
        notice = "没有仍可恢复的后期修改；已永久删除的素材不能通过撤销找回。"
    }
    func flush() async throws {
        saveTask?.cancel()
        if let selected { try await repository.save(selected) }
    }
    func select(_ id: UUID) async {
        guard !recording.isBusy, !busy, !auxiliaryRecording, !exports.working else { error = "请等待当前录制、补拍、预览或文件操作结束再切换工程。"; return }
        do { try await flush(); playback.suspendEngine(); playback.loop = nil; loadedArrangement = nil; selectedID = id; recording.video = selected?.recordVideo ?? true }
        catch { report(error) }
    }
    func preparePlayback(for take: Take? = nil) throws {
        guard let project = selected, !project.archived else { throw StudioError("请先打开本地工程。") }
        let arrangement = take.flatMap { project.arrangement(for: $0) } ?? project.arrangement
        guard let arrangement, let backing = arrangement.backingAssetID, let asset = project.asset(backing) else {
            throw StudioError("这是待分离原曲。当前未启用 AI；请导入已有伴奏版本后录制。")
        }
        if loadedArrangement != arrangement.id {
            playback.loop = nil
            try playback.load(repository.directory(project.id).appendingPathComponent(asset.path), semitones: take?.semitones ?? arrangement.semitones)
            loadedArrangement = arrangement.id
        } else { playback.semitones = take?.semitones ?? arrangement.semitones }
    }
    func importAudio(_ url: URL, isBacking: Bool, newArrangement: Bool, title: String, artist: String) async throws {
        guard !recording.isBusy, !busy, !auxiliaryRecording, !exports.working else { throw StudioError("请等待当前录制、补拍、预览或文件操作结束。") }
        if newArrangement && (selected == nil || selected?.archived == true) { throw StudioError("归档工程需要先恢复源素材；也可取消新版本选项，新建独立工程。") }
        busy = true; defer { busy = false }
        playback.suspendEngine(); playback.loop = nil
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard ["mp3", "m4a", "wav"].contains(url.pathExtension.lowercased()) else { throw StudioError("请选择 MP3、M4A 或 WAV 文件。") }
        let audio = try AVAudioFile(forReading: url)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        guard duration.isFinite && duration > 0 else { throw StudioError("音频无法读取或时长为空。") }
        var project: StudioProject
        let projectID = newArrangement ? (selected?.id ?? UUID()) : UUID()
        let asset = try await repository.importAsset(source: url, projectID: projectID, role: isBacking ? .backing : .source,
                   duration: .init(seconds: duration), sampleRate: audio.processingFormat.sampleRate, channels: Int(audio.processingFormat.channelCount))
        var arrangement = Arrangement(sourceAssetID: asset.id, isBacking: isBacking)
        if newArrangement, var existing = selected {
            arrangement.name = "伴奏 \(existing.arrangements.count + 1)"
            existing.arrangements.append(arrangement); existing.arrangementID = arrangement.id
            existing.assets.append(asset); existing.loopStart = 0; existing.loopEnd = 0
            existing.touch(); project = existing
        } else {
            project = StudioProject(song: Song(title: title.isEmpty ? url.deletingPathExtension().lastPathComponent : title, artist: artist),
                         arrangement: arrangement, assets: [asset], sourceDeviceID: deviceID)
            project.id = projectID
            if let data = UserDefaults.standard.data(forKey: "defaultExportPreset"), let preset = try? JSONDecoder().decode(ExportPreset.self, from: data) { project.exportPreset = preset }
        }
        try await repository.save(project)
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project }
        else { projects.insert(project, at: 0) }
        selectedID = project.id; loadedArrangement = nil
        if !isBacking { notice = "原曲已保留。AI 分离尚未开放；请导入准备好的伴奏作为新版本。" }
    }
    func importVisual(_ url: URL, image: Bool) async throws {
        guard let project = selected, !project.archived, !recording.isBusy, !busy, !auxiliaryRecording, !exports.working else { throw StudioError("请先打开本地工程，并结束录制、补拍、预览或其他文件操作。") }
        busy = true; defer { busy = false }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let duration: Double
        if image {
            guard UIImage(contentsOfFile: url.path) != nil else { throw StudioError("图片无法读取。") }; duration = 0
        } else {
            duration = try await AVURLAsset(url: url).load(.duration).seconds
            guard duration.isFinite, duration > 0, duration < Double(Int64.max) / 600_000 else { throw StudioError("视频时长无效，无法导入。") }
        }
        let asset = try await repository.importAsset(source: url, projectID: project.id, role: image ? .image : .video, duration: .init(seconds: duration))
        guard selectedID == project.id else { throw StudioError("目标工程已切换，导入文件留在原工程目录，未写入其他工程。") }
        if image { try writeThumbnail(from: url, projectID: project.id) }
        update {
            $0.assets.append(asset); $0.edit.visualAssetID = asset.id; $0.edit.visualSongStart = $0.edit.trimStart; $0.edit.visualOffset = 0
            if image && $0.song.coverAssetID == nil { $0.song.coverAssetID = asset.id }
        }
        try await flush()
    }
    func promote(_ takeID: UUID) async throws {
        guard let project = selected, let practice = project.takes.first(where: { $0.id == takeID && $0.isPractice }) else { return }
        if let id = practice.promotedTakeID { update { $0.edit.selectedTakeID = id }; try await flush(); return }
        var take = practice; take.id = UUID(); take.isPractice = false; take.promotedTakeID = nil; take.name = "Audio Take \(project.takes.filter { !$0.isPractice }.count + 1)"
        update {
            $0.takes.append(take); $0.edit.selectedTakeID = take.id
            if let index = $0.takes.firstIndex(where: { $0.id == takeID }) { $0.takes[index].promotedTakeID = take.id }
        }
        try await flush()
    }
    func restore(_ url: URL, keepBoth: Bool) async throws {
        guard !recording.isBusy, !busy, !auxiliaryRecording, !exports.working else { throw StudioError("请等待当前录制、补拍、预览或文件操作结束。") }
        busy = true; defer { busy = false }
        playback.suspendEngine(); playback.loop = nil
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        try await flush()
        let restored = try await repository.restore(archive: url, keepBoth: keepBoth)
        await load(); selectedID = restored.id; loadedArrangement = nil
        notice = "工程已恢复并通过哈希和依赖校验。云端永久保留情况无法验证。"
    }
    func duplicate() async throws {
        guard let project = selected, !project.archived, !recording.isBusy, !busy, !auxiliaryRecording, !exports.working else { throw StudioError("请先打开本地工程，并结束当前操作。") }
        busy = true; defer { busy = false }
        playback.suspendEngine(); playback.loop = nil
        try await flush()
        let copy = try await repository.duplicate(project)
        projects.insert(copy, at: 0); selectedID = copy.id; loadedArrangement = nil
    }
    func recordBackup(_ record: BackupRecord, projectID: UUID) async throws {
        saveTask?.cancel()
        if projectID != selectedID { try await flush() }
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { throw StudioError("备份对应工程不在本地作品库。") }
        if let existing = projects[index].backups.firstIndex(where: { $0.archiveID == record.archiveID }) { projects[index].backups[existing] = record }
        else { projects[index].backups.append(record) }
        // Backup bookkeeping must not advance the content revision and make this backup immediately stale.
        try await repository.save(projects[index])
    }
    func releaseSelected() async throws {
        guard let project = selected, !recording.isBusy, !busy, !auxiliaryRecording, !exports.working else { throw StudioError("请先结束当前录制、预览或文件操作。") }
        saveTask?.cancel()
        if let coverID = project.song.coverAssetID, let cover = project.asset(coverID) {
            try writeThumbnail(from: repository.directory(project.id).appendingPathComponent(cover.path), projectID: project.id)
        }
        let archived = try await repository.releaseLocal(project, confirmedRevision: project.revision)
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = archived }
        playback.suspendEngine(); loadedArrangement = nil
    }
    private func writeThumbnail(from source: URL, projectID: UUID) throws {
        guard let image = UIImage(contentsOfFile: source.path) else { return }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format)
        let thumbnail = renderer.image { context in
            UIColor.systemBackground.setFill(); context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            let scale = max(256 / image.size.width, 256 / image.size.height)
            image.draw(in: CGRect(x: (256 - image.size.width * scale) / 2, y: (256 - image.size.height * scale) / 2,
                                  width: image.size.width * scale, height: image.size.height * scale))
        }
        if let jpeg = thumbnail.jpegData(compressionQuality: 0.8) { try jpeg.write(to: repository.directory(projectID).appendingPathComponent("thumbnail.jpg"), options: .atomic) }
    }
}

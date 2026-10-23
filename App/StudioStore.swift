import SwiftUI
import AVFoundation
import CoverCore

@MainActor final class StudioStore: ObservableObject {
    @Published var projects: [StudioProject] = []
    @Published var selectedID: UUID? {
        didSet { if let selectedID { UserDefaults.standard.set(selectedID.uuidString, forKey: "lastProject") } }
    }
    @Published var error: String?
    @Published var notice: String?
    @Published var busy = false
    @Published var auxiliaryRecording = false
    let repository: ProjectRepository
    let playback = PlaybackEngine()
    let recording: RecordingCoordinator
    let exports = ExportService()
    private var loadedArrangement: UUID?
    private var saveTask: Task<Void, Never>?
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
            let recovered = projects.filter {
                FileManager.default.fileExists(atPath: repository.directory($0.id).appendingPathComponent("recording.json").path)
            }
            if !recovered.isEmpty { notice = "发现上次中断的录制。已提交片段已保存在 Take 中；最后未封装片段可能无法播放，原文件仍保留在工程目录。" }
        } catch { self.error = "作品库读取失败，原文件未修改。\(error.localizedDescription)" }
    }
    func report(_ error: Error) { self.error = error.localizedDescription }
    func update(_ mutate: (inout StudioProject) -> Void) {
        guard let id = selectedID, let index = projects.firstIndex(where: { $0.id == id }), !projects[index].archived else { return }
        mutate(&projects[index]); projects[index].touch()
        let project = projects[index]
        saveTask?.cancel()
        saveTask = Task {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                try await repository.save(project)
            } catch is CancellationError {} catch { report(error) }
        }
    }
    func flush() async throws {
        saveTask?.cancel()
        if let selected { try await repository.save(selected) }
    }
    func select(_ id: UUID) async {
        guard !recording.isBusy, !busy, !auxiliaryRecording else { error = "请等待当前录制、补拍或文件操作结束再切换工程。"; return }
        do { try await flush(); playback.suspendEngine(); playback.loop = nil; loadedArrangement = nil; selectedID = id }
        catch { report(error) }
    }
    func preparePlayback(for take: Take? = nil) throws {
        guard let project = selected, !project.archived else { throw StudioError("请先打开本地工程。") }
        let arrangement = take.flatMap { project.arrangement(for: $0) } ?? project.arrangement
        guard let arrangement, let backing = arrangement.backingAssetID, let asset = project.asset(backing) else {
            throw StudioError("这是待分离原曲。当前未启用 AI；请导入已有伴奏版本后录制。")
        }
        if loadedArrangement != arrangement.id {
            try playback.load(repository.directory(project.id).appendingPathComponent(asset.path), semitones: take?.semitones ?? arrangement.semitones)
            loadedArrangement = arrangement.id
        } else { playback.semitones = take?.semitones ?? arrangement.semitones }
    }
    func importAudio(_ url: URL, isBacking: Bool, newArrangement: Bool, title: String, artist: String) async throws {
        guard !recording.isBusy, !busy, !auxiliaryRecording else { throw StudioError("请等待当前录制、补拍或文件操作结束。") }
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
        }
        try await repository.save(project)
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project }
        else { projects.insert(project, at: 0) }
        selectedID = project.id; loadedArrangement = nil
        if !isBacking { notice = "原曲已保留。AI 分离尚未开放；请导入准备好的伴奏作为新版本。" }
    }
    func importVisual(_ url: URL, image: Bool) async throws {
        guard let project = selected, !project.archived, !recording.isBusy, !busy, !auxiliaryRecording else { throw StudioError("请先打开本地工程，并结束录制、补拍或其他文件操作。") }
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
        update { $0.assets.append(asset); $0.edit.visualAssetID = asset.id }
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
        guard !recording.isBusy, !busy, !auxiliaryRecording else { throw StudioError("请等待当前录制、补拍或文件操作结束。") }
        busy = true; defer { busy = false }
        playback.suspendEngine(); playback.loop = nil
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        try await flush()
        let restored = try await repository.restore(archive: url, keepBoth: keepBoth)
        await load(); selectedID = restored.id; loadedArrangement = nil
        notice = "工程已恢复并通过哈希和依赖校验。云端永久保留情况无法验证。"
    }
    func duplicate() async throws {
        guard let project = selected, !project.archived, !recording.isBusy, !busy, !auxiliaryRecording else { throw StudioError("请先打开本地工程，并结束当前操作。") }
        busy = true; defer { busy = false }
        playback.suspendEngine(); playback.loop = nil
        try await flush()
        let copy = try await repository.duplicate(project)
        projects.insert(copy, at: 0); selectedID = copy.id; loadedArrangement = nil
    }
    func recordBackup(_ record: BackupRecord, projectID: UUID) async throws {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { throw StudioError("备份对应工程不在本地作品库。") }
        if let existing = projects[index].backups.firstIndex(where: { $0.archiveID == record.archiveID }) { projects[index].backups[existing] = record }
        else { projects[index].backups.append(record) }
        // Backup bookkeeping must not advance the content revision and make this backup immediately stale.
        try await repository.save(projects[index])
    }
    func releaseSelected() async throws {
        guard let project = selected else { return }
        saveTask?.cancel()
        let archived = try await repository.releaseLocal(project, confirmedRevision: project.revision)
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = archived }
        playback.suspendEngine(); loadedArrangement = nil
    }
}

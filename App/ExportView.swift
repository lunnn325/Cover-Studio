import SwiftUI
import CoverCore

struct ExportView: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) var dismiss
    @ObservedObject var service: ExportService
    @State private var share = false
    @State private var files = false
    @State private var archive = false
    var body: some View {
        List {
            Section("输出预设") {
                ForEach(ExportVariant.allCases, id: \.self) { variant in
                    Toggle(variant.label, isOn: Binding(get: { store.selected?.exportPreset.variants.contains(variant) ?? false }, set: { enabled in
                        store.update { if enabled { $0.exportPreset.variants.insert(variant) } else { $0.exportPreset.variants.remove(variant) } }
                    }))
                }
                Picker("音频文件格式", selection: store.binding(\.exportPreset.audioFormat, fallback: .m4a)) {
                    Text("M4A / AAC").tag(AudioExportFormat.m4a)
                    Text("WAV / 48kHz PCM").tag(AudioExportFormat.wav)
                }
                Text("首次默认双版本视频，之后记住你的选择。1080p / 30fps，MP4 + AAC。歌词未同步时需先标记，或取消带字幕版本。").font(.footnote).foregroundStyle(.secondary)
            }.disabled(service.working)
            Section {
                Button("开始顺序导出") { run() }.disabled(service.working || store.recording.isBusy)
                if service.working { ProgressView(service.stage) }
                if let failure = service.failure { Text(failure).foregroundStyle(.orange) }
                ForEach(service.jobs) { job in
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent(job.variant.label, value: job.status)
                        if let error = job.error { Text(error).font(.footnote).foregroundStyle(.orange) }
                        if job.status == "失败" || job.status == "中断" { Button("单独重试") { run(retry: job.variant) }.disabled(service.working) }
                    }
                }
                if !service.shareURLs.isEmpty {
                    Button("保存已完成文件到 Files") { files = true }.disabled(service.working)
                    Button("分享已完成文件") { share = true }.disabled(service.working)
                }
            } footer: { Text("失败不会删除源文件或已完成项。更换文件提供者目标不能减少本地渲染的最低临时空间。") }
            Section { Button("导出可编辑工程包") { archive = true } }
        }
        .navigationTitle("导出").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(service.working) } }
        .task { if let project = store.selected { service.load(root: store.repository.directory(project.id), projectID: project.id, exportedAssets: project.assets) } }
        .sheet(isPresented: $share) { ShareSheet(urls: service.shareURLs) }
        .sheet(isPresented: $files) { DocumentExportPicker(urls: service.shareURLs) { success in files = false; if success { store.notice = "已交给文件提供者；不代表云端上传完成。" } } }
        .sheet(isPresented: $archive) { NavigationStack { ArchiveView() } }
        .interactiveDismissDisabled(service.working)
    }
    func run(retry: ExportVariant? = nil) {
        guard let project = store.selected else { return }
        store.playback.suspendEngine()
        Task {
            do { try await store.flush(); await service.run(project: project, root: store.repository.directory(project.id), retry: retry) }
            catch { store.report(error) }
        }
    }
}

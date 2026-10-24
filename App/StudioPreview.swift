import AVFoundation
import CoverCore

/// Owns only rebuildable preview files. Closing never touches media or exports.
@MainActor final class StudioPreview: Identifiable {
    let id = UUID()
    let title: String
    let player: AVPlayer
    let cacheDirectory: URL
    private var closed = false

    init(title: String, item: AVPlayerItem, cacheDirectory: URL) {
        self.title = title; self.player = AVPlayer(playerItem: item); self.cacheDirectory = cacheDirectory
    }
    func close() {
        guard !closed else { return }
        closed = true; player.pause(); player.replaceCurrentItem(with: nil)
        // This URL is generated internally, never supplied by an imported manifest.
        guard cacheDirectory.lastPathComponent.hasPrefix("preview-"), cacheDirectory.deletingLastPathComponent().lastPathComponent == "cache" else { return }
        try? FileManager.default.removeItem(at: cacheDirectory)
    }
}

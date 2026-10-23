#if DEBUG
import AVFoundation
import UIKit
import CoverCore
import Combine

/// Opt-in simulator check of real offline rendering and archive APIs, using only generated fixtures.
@MainActor enum MediaSmokeCheck {
    private static var didRun = false
    private struct Output: Codable {
        var variant: String
        var file: String
        var bytes: Int64
        var duration: Double
        var audioTracks: Int
        var videoTracks: Int
        var peak: Float?
        var estimatedHz: Double?
        var zeroCrossingHz: Double?
    }
    private struct Report: Codable {
        var passed = false
        var stage = "fixture"
        var errors: [String] = []
        var scope = "Synthetic offline only: generated two-second sine WAVs and geometric JPEG; real export/archive APIs. Does not validate microphone, camera, AirPods, acoustic sync, listening quality, subtitle appearance, cloud upload, or real-device performance."
        var startedAt = Date()
        var finishedAt: Date?
        var runtime = ProcessInfo.processInfo.operatingSystemVersionString
        var temporaryRoot: String
        var outputs: [Output] = []
        var archiveRestored = false
        var subtitleChangedPixels: [Int] = []
    }

    static func runIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("--media-smoke"), !didRun else { return }
        didRun = true
        let files = FileManager.default
        let temporaryRoot = files.temporaryDirectory.appendingPathComponent("MediaSmoke-" + UUID().uuidString, isDirectory: true)
        var report = Report(temporaryRoot: temporaryRoot.path)
        guard let documents = files.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("MediaSmokeCheck: Documents is unavailable"); return
        }
        let reportURL = documents.appendingPathComponent("MediaSmokeReport.json")
        do {
            try files.createDirectory(at: documents, withIntermediateDirectories: true)
            try write(report, to: reportURL) // A terminated run leaves passed=false and finishedAt absent.
            let root = temporaryRoot.appendingPathComponent("fixture", isDirectory: true)
            try files.createDirectory(at: root.appendingPathComponent("media"), withIntermediateDirectories: true)
            let backingURL = root.appendingPathComponent("media/backing.wav")
            let vocalURL = root.appendingPathComponent("media/vocal.wav")
            try sine(to: backingURL, frequency: 220)
            try sine(to: vocalURL, frequency: 440)
            let imageURL = root.appendingPathComponent("media/geometry.jpg")
            let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 360)).image { context in
                UIColor(red: 0.12, green: 0.22, blue: 0.35, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
                UIColor.orange.setFill(); context.fill(CGRect(x: 80, y: 80, width: 160, height: 200))
                UIColor.white.setFill(); UIBezierPath(ovalIn: CGRect(x: 330, y: 90, width: 180, height: 180)).fill()
            }
            guard let jpeg = image.jpegData(compressionQuality: 0.9) else { throw StudioError("Smoke JPEG generation failed") }
            try jpeg.write(to: imageURL)
            let backing = try asset(backingURL, role: .backing), vocal = try asset(vocalURL, role: .vocal)
            let visual = try asset(imageURL, role: .image)
            var arrangement = Arrangement(sourceAssetID: backing.id, isBacking: true)
            arrangement.semitones = 3
            arrangement.lyrics.lines = [.init(text: "Synthetic first line", time: 0), .init(text: "合成第二句", time: 1)]
            var project = StudioProject(song: .init(title: "Offline media smoke"), arrangement: arrangement,
                                        assets: [backing, vocal, visual], sourceDeviceID: "synthetic-offline-smoke")
            var take = Take(name: "Generated Audio Take", kind: .audio, arrangementID: arrangement.id, semitones: 3)
            take.segments = [.init(vocalAssetID: vocal.id, videoAssetID: nil, songStart: .init(seconds: 0),
                hostStart: .init(seconds: 0), duration: .init(seconds: 2), audioFirstPTS: .init(seconds: 0),
                videoFirstPTS: nil, playbackHostTime: 0, inputLatency: 0, outputLatency: 0, route: "synthetic offline; no capture")]
            project.takes = [take]; project.edit.selectedTakeID = take.id; project.edit.visualAssetID = visual.id
            project.edit.aspect = 16.0 / 9.0; project.edit.reverb = 0
            let expected: Set<ExportVariant> = [.cleanVideo, .subtitledVideo, .mixAudio, .backing, .dryVocal]
            project.exportPreset.variants = expected; project.exportPreset.audioFormat = .wav
            try ProjectRules.validate(project)
            let exports = ExportService()
            let observation = exports.$stage.sink { stage in
                report.stage = "export: " + stage
                try? write(report, to: reportURL)
            }
            defer { observation.cancel() }
            await exports.run(project: project, root: root)
            report.stage = "inspect outputs"; try write(report, to: reportURL)
            if let failure = exports.failure { report.errors.append("Export service: " + failure) }
            for variant in ExportVariant.allCases where expected.contains(variant) {
                do {
                    guard let job = exports.jobs.first(where: { $0.variant == variant }), job.status == "完成", let path = job.path else {
                        throw StudioError(exports.jobs.first(where: { $0.variant == variant })?.error ?? "No completed output")
                    }
                    if variant == .backing {
                        let diagnostic = documents.appendingPathComponent("MediaSmokeAudio", isDirectory: true)
                        try files.createDirectory(at: diagnostic, withIntermediateDirectories: true)
                        let copy = diagnostic.appendingPathComponent("backing.wav")
                        if files.fileExists(atPath: copy.path) { try files.removeItem(at: copy) }
                        try files.copyItem(at: root.appendingPathComponent(path), to: copy)
                    }
                    let output = try await inspect(root.appendingPathComponent(path), variant: variant)
                    report.outputs.append(output)
                } catch { report.errors.append(variant.rawValue + ": " + error.localizedDescription) }
            }
            do {
                report.stage = "inspect subtitle frames"; try write(report, to: reportURL)
                guard let clean = exports.jobs.first(where: { $0.variant == .cleanVideo && $0.status == "完成" })?.path,
                      let subtitled = exports.jobs.first(where: { $0.variant == .subtitledVideo && $0.status == "完成" })?.path else {
                    throw StudioError("Both video variants are required for subtitle frame inspection")
                }
                let frames = documents.appendingPathComponent("MediaSmokeFrames", isDirectory: true)
                try files.createDirectory(at: frames, withIntermediateDirectories: true)
                let baseline = try await snapshot(root.appendingPathComponent(clean), seconds: 0.25, to: frames.appendingPathComponent("clean.png"))
                for (index, seconds) in [0.25, 1.25].enumerated() {
                    let pixels = try await snapshot(root.appendingPathComponent(subtitled), seconds: seconds, to: frames.appendingPathComponent("subtitle-\(index + 1).png"))
                    var changed = 0
                    for pixel in stride(from: 0, to: baseline.count, by: 4) {
                        if (0..<3).contains(where: { abs(Int(pixels[pixel + $0]) - Int(baseline[pixel + $0])) > 48 }) { changed += 1 }
                    }
                    report.subtitleChangedPixels.append(changed)
                    guard changed > 40 else { throw StudioError("Subtitle frame lacks visible overlay pixels at \(seconds)s") }
                }
            } catch { report.errors.append("Subtitle frames: " + error.localizedDescription) }
            // The source-only full archive is restored into a new, isolated repository, never the user's library.
            do {
                report.stage = "archive roundtrip"; try write(report, to: reportURL)
                let archive = temporaryRoot.appendingPathComponent("fixture.coverproject")
                try ProjectArchive.create(project: project, root: root, destination: archive, mode: .full)
                let restoredRepository = try ProjectRepository(root: temporaryRoot.appendingPathComponent("restored-library"))
                let restored = try await restoredRepository.restore(archive: archive)
                guard restored.assets.count == project.assets.count, restored.takes == project.takes,
                      restored.arrangement?.lyrics == project.arrangement?.lyrics, restored.edit == project.edit else {
                    throw StudioError("Restored project metadata differs")
                }
                for asset in restored.assets {
                    let url = restoredRepository.directory(restored.id).appendingPathComponent(asset.path)
                    guard try FileIntegrity.size(url) == asset.bytes, try FileIntegrity.sha256(url) == asset.sha256 else {
                        throw StudioError("Restored source bytes differ")
                    }
                }
                report.archiveRestored = true
            } catch { report.errors.append("Archive roundtrip: " + error.localizedDescription) }
            report.passed = report.errors.isEmpty && report.outputs.count == expected.count && report.archiveRestored
        } catch { report.errors.append("Fixture/setup: " + error.localizedDescription) }
        report.finishedAt = Date()
        report.stage = "finished"
        do { try write(report, to: reportURL) }
        catch { print("MediaSmokeCheck: report write failed: \(error.localizedDescription)") }
        // Generated media is retained under temporaryRoot for inspection; it is never registered in the user library.
        print("MediaSmokeCheck finished: passed=\(report.passed), report=\(reportURL.path)")
    }

    private static func write(_ report: Report, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: url, options: .atomic)
    }
    private static func asset(_ url: URL, role: AssetRole) throws -> MediaAsset {
        try MediaAsset(path: "media/" + url.lastPathComponent, role: role, bytes: FileIntegrity.size(url),
                       sha256: FileIntegrity.sha256(url), duration: .init(seconds: role == .image ? 0 : 2),
                       sampleRate: role == .image ? nil : 48_000, channels: role == .image ? nil : 2)
    }
    private static func sine(to url: URL, frequency: Double) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000), let channels = buffer.floatChannelData else {
            throw StudioError("Synthetic audio buffer unavailable")
        }
        buffer.frameLength = 96_000
        for frame in 0..<96_000 {
            let fade = min(1, min(Double(frame), Double(95_999 - frame)) / 960)
            let sample = Float(0.1 * fade * sin(2 * .pi * frequency * Double(frame) / 48_000))
            channels[0][frame] = sample; channels[1][frame] = sample
        }
        let writer = try AVAudioFile(forWriting: url, settings: format.settings)
        try writer.write(from: buffer)
    }
    private static func inspect(_ url: URL, variant: ExportVariant) async throws -> Output {
        let bytes = try FileIntegrity.size(url), media = AVURLAsset(url: url)
        let duration = try await media.load(.duration).seconds
        let audio = try await media.loadTracks(withMediaType: .audio)
        let video = try await media.loadTracks(withMediaType: .video)
        let needsVideo = variant == .cleanVideo || variant == .subtitledVideo
        guard bytes > 0, duration.isFinite, abs(duration - 2) <= 0.2, !audio.isEmpty,
              needsVideo ? !video.isEmpty : video.isEmpty else { throw StudioError("Output size/duration/tracks failed validation") }
        var peak: Float?
        var estimatedHz: Double?
        var zeroCrossingHz: Double?
        if url.pathExtension.lowercased() == "wav" {
            let reader = try AVAudioFile(forReading: url)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 4096) else { throw StudioError("Output PCM buffer unavailable") }
            var maximum: Float = 0, previous: Float = 0
            var absoluteFrame: Int64 = 0, measuredFrames: Int64 = 0, crossings = 0
            var window: [Double] = []
            let rate = reader.processingFormat.sampleRate
            while reader.framePosition < reader.length {
                try reader.read(into: buffer)
                guard let samples = buffer.floatChannelData else { throw StudioError("Output cannot be decoded as float PCM") }
                for frame in 0..<Int(buffer.frameLength) {
                    let sample = samples[0][frame]
                    maximum = max(maximum, abs(sample))
                    let seconds = Double(absoluteFrame) / rate
                    if seconds >= 0.4 && seconds < 1.6 {
                        if previous <= 0 && sample > 0 { crossings += 1 }
                        measuredFrames += 1
                        if absoluteFrame % 4 == 0 { window.append(Double(sample)) }
                    }
                    previous = sample; absoluteFrame += 1
                }
            }
            guard maximum.isFinite, maximum > 0.0001 else { throw StudioError("Synthetic WAV output is silent") }
            peak = maximum
            if variant == .backing || variant == .dryVocal {
                zeroCrossingHz = Double(crossings) * rate / Double(max(1, measuredFrames))
                // A phase-vocoder can add low-level sidebands or DC bias; raw
                // sign crossings need not equal its dominant audible frequency.
                // Measure the Hann-windowed spectrum independently and retain
                // both readings plus the generated WAV for inspection.
                let measured = dominantFrequency(window, sampleRate: rate / 4)
                let expected = variant == .backing ? 220 * pow(2, 3.0 / 12) : 440
                guard abs(measured - expected) < 3 else { throw StudioError("Pitch-preserving-speed check failed: measured \(measured)Hz, expected \(expected)Hz") }
                estimatedHz = measured
            }
        }
        return Output(variant: variant.rawValue, file: url.path, bytes: bytes, duration: duration,
                      audioTracks: audio.count, videoTracks: video.count, peak: peak, estimatedHz: estimatedHz, zeroCrossingHz: zeroCrossingHz)
    }
    private static func dominantFrequency(_ values: [Double], sampleRate: Double) -> Double {
        guard values.count > 1 else { return 0 }
        let weighted = values.enumerated().map { index, value in
            value * (0.5 - 0.5 * cos(2 * .pi * Double(index) / Double(values.count - 1)))
        }
        var strongest: Double = 0, peakFrequency: Double = 0
        for step in 200...1100 {
            let frequency = Double(step) / 2
            let coefficient = 2 * cos(2 * .pi * frequency / sampleRate)
            var previous: Double = 0, earlier: Double = 0
            for value in weighted {
                let current = value + coefficient * previous - earlier
                earlier = previous; previous = current
            }
            let power = previous * previous + earlier * earlier - coefficient * previous * earlier
            if power > strongest { strongest = power; peakFrequency = frequency }
        }
        return peakFrequency
    }
    private static func snapshot(_ url: URL, seconds: Double, to output: URL) async throws -> [UInt8] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        let frame = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        var pixels = [UInt8](repeating: 0, count: 640 * 360 * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            guard let bitmap = CGContext(data: bytes.baseAddress, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 640 * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw StudioError("Frame inspection buffer unavailable") }
            bitmap.draw(frame, in: CGRect(x: 0, y: 0, width: 640, height: 360))
            guard let image = bitmap.makeImage(), let png = UIImage(cgImage: image).pngData() else { throw StudioError("Frame evidence unavailable") }
            try png.write(to: output)
        }
        return pixels
    }
}
#endif

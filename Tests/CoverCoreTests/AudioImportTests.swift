import XCTest
import AVFAudio
@testable import CoverCore

final class AudioImportTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "AudioFixtures"))
    }
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AudioImportTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func checkPCM(_ url: URL, channels: Int, rate: Double) throws {
        let reader = try AVAudioFile(forReading: url)
        XCTAssertEqual(reader.processingFormat.sampleRate, rate, accuracy: 0.1)
        XCTAssertEqual(Int(reader.processingFormat.channelCount), channels)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: AVAudioFrameCount(reader.length)))
        try reader.read(into: buffer)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        let count = Int(buffer.frameLength)
        XCTAssertGreaterThan(count, 15000)
        var peak: Float = 0, crossings = 0
        for index in 0..<count {
            XCTAssertTrue(samples[index].isFinite)
            peak = max(peak, abs(samples[index]))
        }
        // AAC/MP3 containers may retain encoder padding; measure the interior tone.
        let margin = Int(rate * 0.1)
        for index in margin..<(count-margin) {
            if samples[index-1] <= 0 && samples[index] > 0 { crossings += 1 }
        }
        XCTAssertGreaterThan(peak, 0.02); XCTAssertLessThan(peak, 0.5)
        XCTAssertEqual(Double(crossings) * rate / Double(count-margin*2), 440, accuracy: 8)
    }
    func testVorbisDecodesRealMonoAndStereoPCMAndPreservesOriginal() throws {
        let temp = try temporary(); defer { try? FileManager.default.removeItem(at: temp) }
        for (name,channels,rate) in [("mono-44100.ogg",1,44100.0),("stereo-48000.ogg",2,48000.0)] {
            let source = try fixture(name), hash = try FileIntegrity.sha256(source)
            let prepared = try AudioImport.prepare(source, temporaryRoot: temp)
            XCTAssertTrue(prepared.converted); XCTAssertEqual(prepared.channels,channels)
            XCTAssertEqual(prepared.sampleRate,rate); XCTAssertEqual(prepared.duration.seconds,0.5,accuracy:0.001)
            try checkPCM(prepared.playbackURL, channels: channels, rate: rate)
            prepared.removeTemporaryFiles()
            XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.playbackURL.path))
            XCTAssertEqual(try FileIntegrity.sha256(source),hash)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: temp.path).isEmpty)
    }
    func testExpandedNativeAndLegacyFormatsActuallyDecode() throws {
        for ext in ["mp3","m4a","wav","aac","flac","aiff","caf"] {
            let source = try fixture("tone." + ext)
            let prepared = try AudioImport.prepare(source)
            XCTAssertFalse(prepared.converted,ext)
            XCTAssertTrue((0.45...0.65).contains(prepared.duration.seconds),ext)
            try checkPCM(prepared.playbackURL, channels: 2, rate: 48000)
            prepared.removeTemporaryFiles()
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        }
    }
    func testMalformedTruncatedChainedAndOpusAreRejectedWithoutPartialSuccess() throws {
        let temp = try temporary(); defer { try? FileManager.default.removeItem(at: temp) }
        let original = try Data(contentsOf: fixture("stereo-48000.ogg"))
        var badCRC = original; badCRC[badCRC.count-1] ^= 1
        let variants = [Data(original.dropLast(40)),badCRC,original+original,Data("not ogg".utf8),try Data(contentsOf: fixture("opus.ogg"))]
        for (index,data) in variants.enumerated() {
            let url = temp.appendingPathComponent("invalid-\(index).ogg")
            try data.write(to: url)
            XCTAssertThrowsError(try AudioImport.prepare(url,temporaryRoot:temp))
            XCTAssertEqual(try Data(contentsOf:url),data)
        }
        let paths = try FileManager.default.contentsOfDirectory(atPath:temp.path)
        XCTAssertFalse(paths.contains { $0.hasPrefix("AudioImport-") })
    }
    func testOriginalAndDecodedDependencySurviveEveryBackupMode() async throws {
        let temp = try temporary(); defer { try? FileManager.default.removeItem(at: temp) }
        let source = try fixture("stereo-48000.ogg"), originalHash = try FileIntegrity.sha256(source)
        let prepared = try AudioImport.prepare(source,temporaryRoot:temp)
        defer { prepared.removeTemporaryFiles() }
        let repo = try ProjectRepository(root:temp.appendingPathComponent("library"))
        let id = UUID()
        let imported = try await repo.importPreparedAudio(prepared,projectID:id,isBacking:true)
        var project = StudioProject(song:.init(title:"Generated OGG"),arrangement:imported.arrangement,assets:imported.assets,sourceDeviceID:"test")
        project.id = id; try await repo.save(project)
        XCTAssertEqual(imported.assets.count,2)
        XCTAssertNotEqual(imported.arrangement.sourceAssetID,imported.arrangement.backingAssetID)
        XCTAssertEqual(project.asset(imported.arrangement.sourceAssetID)?.sha256,originalHash)
        prepared.removeTemporaryFiles()
        for mode in [BackupMode.full,.slim,.custom] {
            let archive = temp.appendingPathComponent(mode.rawValue+".coverproject")
            try ProjectArchive.create(project:project,root:repo.directory(id),destination:archive,mode:mode)
            let restored = temp.appendingPathComponent("restored-"+mode.rawValue)
            let manifest = try ProjectArchive.inspect(archive,extractTo:restored)
            XCTAssertEqual(manifest.project.assets.count,2)
            let original = try XCTUnwrap(manifest.project.asset(imported.arrangement.sourceAssetID))
            XCTAssertEqual(try FileIntegrity.sha256(restored.appendingPathComponent(original.path)),originalHash)
            let decoded = try XCTUnwrap(manifest.project.asset(imported.arrangement.backingAssetID!))
            try checkPCM(restored.appendingPathComponent(decoded.path),channels:2,rate:48000)
        }
    }
    func testChangedSourceRefusesCommitAndOriginalOnlyDoesNotInventBacking() async throws {
        let temp = try temporary(); defer { try? FileManager.default.removeItem(at:temp) }
        let source = temp.appendingPathComponent("input.ogg")
        try FileManager.default.copyItem(at:fixture("stereo-48000.ogg"),to:source)
        let prepared = try AudioImport.prepare(source,temporaryRoot:temp); defer { prepared.removeTemporaryFiles() }
        let repo = try ProjectRepository(root:temp.appendingPathComponent("library"))
        let imported = try await repo.importPreparedAudio(prepared,projectID:UUID(),isBacking:false)
        XCTAssertNil(imported.arrangement.backingAssetID)
        XCTAssertEqual(imported.assets.count,1); XCTAssertEqual(imported.assets.first?.role,.source)
        var changed = try Data(contentsOf:source); changed[changed.count-1] ^= 1; try changed.write(to:source)
        do { _ = try await repo.importPreparedAudio(prepared,projectID:UUID(),isBacking:true); XCTFail("Changed source was accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("变化")) }
    }
}

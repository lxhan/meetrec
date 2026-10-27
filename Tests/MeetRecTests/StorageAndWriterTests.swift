import XCTest
import AVFoundation
@testable import MeetRec

final class StorageAndWriterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try RecordingStorage.prepareDirectory(directory)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testSameSecondProducesUniqueNames() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        let urls = try (0..<100).map { _ in try RecordingStorage.outputURL(in: directory, date: date) }
        XCTAssertEqual(Set(urls).count, 100)
    }

    func testDirectoryIsOwnerOnly() throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testDirectorySymlinkRejected() throws {
        let link = directory.appendingPathComponent("link")
        let target = directory.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try RecordingStorage.prepareDirectory(link))
    }

    func testExistingFileNeverDeletedOnWriterInit() throws {
        let url = directory.appendingPathComponent("existing.m4a")
        let data = Data("important recording".utf8)
        try data.write(to: url)
        XCTAssertThrowsError(try StereoWriter(outputURL: url))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testDanglingOutputSymlinkRejected() throws {
        let link = directory.appendingPathComponent("recording.m4a")
        try FileManager.default.createSymbolicLink(at: link,
            withDestinationURL: directory.appendingPathComponent("missing.m4a"))
        XCTAssertThrowsError(try StereoWriter(outputURL: link))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
    }

    func testCopyOwnsAudioMemory() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        source.frameLength = 4
        source.floatChannelData![0][0] = 0.25
        let copy = StereoWriter.copyBuffer(source)!
        source.floatChannelData![0][0] = 0.9
        XCTAssertEqual(copy.floatChannelData![0][0], 0.25)
    }

    func testSoftClipIsBoundedAndHandlesNonFiniteInput() {
        for x: Float in [-10, -1, -0.5, 0, 0.5, 1, 10] {
            XCTAssertLessThanOrEqual(abs(StereoWriter.softClip(x)), 1)
        }
        XCTAssertEqual(StereoWriter.softClip(.nan), 0)
        XCTAssertEqual(StereoWriter.softClip(.infinity), 0)
        XCTAssertEqual(StereoWriter.softClip(0.5), 0.5)
    }

    func testConcurrentMuteAndCaptureSubmission() async throws {
        let url = try RecordingStorage.outputURL(in: directory)
        let writer = try StereoWriter(outputURL: url)
        try writer.start()
        let host = mach_absolute_time()
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
            buffer.frameLength = 480
            for j in 0..<480 { buffer.floatChannelData![0][j] = 0.1 }
            writer.setMuted(system: i % 2 == 0, mic: i % 3 == 0)
            writer.appendMic(buffer: buffer, time: AVAudioTime(hostTime: host))
            writer.appendSystem(buffer: buffer, time: AVAudioTime(hostTime: host))
        }
        try await writer.finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testMissingHostTimestampFailsExplicitly() async throws {
        let writer = try StereoWriter(outputURL: RecordingStorage.outputURL(in: directory))
        let reported = expectation(description: "timestamp error surfaced")
        writer.onFailure = { error in
            XCTAssertTrue(error.localizedDescription.contains("timestamp"))
            reported.fulfill()
        }
        try writer.start()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        writer.appendMic(buffer: buffer, time: AVAudioTime(sampleTime: 0, atRate: 48_000))
        await fulfillment(of: [reported], timeout: 2)
        do {
            try await writer.finish()
            XCTFail("Missing timestamp must not become successful save")
        } catch {}
    }

    func testWriterFailurePreservesBufferedAudioForRecovery() async throws {
        let writer = try StereoWriter(outputURL: RecordingStorage.outputURL(in: directory))
        try writer.start()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        for i in 0..<4_800 { buffer.floatChannelData![0][i] = 0.25 }
        writer.appendMic(buffer: buffer, time: AVAudioTime(hostTime: mach_absolute_time()))
        // Force an input failure after valid data has been accepted.
        writer.appendMic(buffer: buffer, time: AVAudioTime(sampleTime: 0, atRate: 48_000))
        do { try await writer.finish(); XCTFail("Expected explicit writer failure") } catch {}
        XCTAssertFalse(try RecordingRecovery.pending(in: directory).isEmpty)
        let result = RecordingRecovery.recoverAll(in: directory)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertEqual(try AVAudioFile(forReading: XCTUnwrap(result.files.first)).length, 4_800)
    }

    func testResampledTimelineHasNoPrimingGapsOrLostTail() async throws {
        let writer = try StereoWriter(outputURL: RecordingStorage.outputURL(in: directory))
        try writer.start()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let host = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441)!
        buffer.frameLength = 441
        for j in 0..<441 { buffer.floatChannelData![0][j] = 0.1 }
        for i in 0..<100 {
            let time = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: host + Double(i) * 0.01))
            writer.appendMic(buffer: buffer, time: time)
        }
        writer.appendMic(buffer: buffer, time: AVAudioTime(sampleTime: 0, atRate: 44_100))
        do { try await writer.finish(); XCTFail("Expected injected timestamp error") } catch {}
        let recovery = RecordingRecovery.recoverAll(in: directory)
        XCTAssertTrue(recovery.errors.isEmpty, "\(recovery.errors)")
        let audio = try AVAudioFile(forReading: XCTUnwrap(recovery.files.first))
        XCTAssertEqual(audio.length, 48_000)
    }

    /// Synthetic PCM only: no device capture, UI, microphone or screen permission.
    func testFinishDrainsMoreThanOneHeartbeatAndSecuresFile() async throws {
        let url = try RecordingStorage.outputURL(in: directory)
        let writer = try StereoWriter(outputURL: url)
        try writer.start()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let host = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        for i in 0..<12 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
            buffer.frameLength = 4_800
            for j in 0..<4_800 { buffer.floatChannelData![0][j] = 0.1 }
            let time = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: host + Double(i) * 0.1))
            writer.appendMic(buffer: buffer, time: time)
            writer.appendSystem(buffer: buffer, time: time)
        }
        try await writer.finish()
        let duration = try await AVURLAsset(url: url).load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 1.2, accuracy: 0.08)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertTrue(try RecordingRecovery.pending(in: directory).isEmpty)
    }
}

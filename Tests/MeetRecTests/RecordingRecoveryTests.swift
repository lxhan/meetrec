import XCTest
import AVFoundation
import Darwin
import MachO
@testable import MeetRec

final class RecordingRecoveryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try RecordingStorage.prepareDirectory(directory)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func journal() throws -> RecordingJournal {
        try RecordingJournal(outputURL: directory.appendingPathComponent("call.m4a"))
    }

    func testRecoveryProducesPlayableOwnerOnlyAudioAndRemovesJournal() throws {
        let journal = try journal()
        let samples = (0..<48_000).map { Float(sin(Double($0) * 0.1) * 0.2) }
        try journal.append(samples)
        journal.retainForRecovery()
        let result = RecordingRecovery.recoverAll(in: directory)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let output = try XCTUnwrap(result.files.first)
        let audio = try AVAudioFile(forReading: output)
        XCTAssertEqual(audio.length, 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 48_000)!
        var decoded: [Float] = []
        while audio.framePosition < audio.length {
            try audio.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            decoded.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        XCTAssertEqual(decoded.count, samples.count)
        for i in [0, 1, 100, 24_000, 47_999] where i < decoded.count {
            XCTAssertEqual(decoded[i], samples[i], accuracy: 0.00001)
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: output.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertTrue(try RecordingRecovery.pending(in: directory).isEmpty)
    }

    func testActiveJournalSkippedByRecovery() throws {
        let journal = try journal()
        try journal.append([0.1, 0.2])
        let result = RecordingRecovery.recoverAll(in: directory)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.directory.path))
        journal.retainForRecovery()
    }

    func testPartRotationRecoversAllFramesInOrder() throws {
        let journal = try journal()
        try journal.append(Array(repeating: 0.1, count: RecordingJournal.framesPerPart))
        try journal.append(Array(repeating: 0.2, count: 4_800))
        journal.retainForRecovery()
        let result = RecordingRecovery.recoverAll(in: directory)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let file = try AVAudioFile(forReading: XCTUnwrap(result.files.first))
        XCTAssertEqual(file.length, Int64(RecordingJournal.framesPerPart + 4_800))
        file.framePosition = Int64(RecordingJournal.framesPerPart)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1)!
        try file.read(into: buffer, frameCount: 1)
        XCTAssertEqual(buffer.floatChannelData![0][0], 0.2)
    }

    func testPartialFinalFloatIsTrimmed() throws {
        let journal = try journal()
        try journal.append([0.25, 0.5])
        journal.retainForRecovery()
        let handle = try FileHandle(forWritingTo: journal.directory.appendingPathComponent("000000.pcm"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0xff, 0xff]))
        try handle.close()
        let result = RecordingRecovery.recoverAll(in: directory)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertEqual(try AVAudioFile(forReading: XCTUnwrap(result.files.first)).length, 2)
    }

    func testMissingPartDoesNotDeleteRemainingSource() throws {
        let journal = try journal()
        try journal.append(Array(repeating: 0.1, count: RecordingJournal.framesPerPart + 1))
        journal.retainForRecovery()
        try FileManager.default.removeItem(at: journal.directory.appendingPathComponent("000000.pcm"))
        let result = RecordingRecovery.recoverAll(in: directory)
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.directory.appendingPathComponent("000001.pcm").path))
    }

    func testSymlinkPartRejectedWithoutDeletingTarget() throws {
        let journal = try journal()
        journal.retainForRecovery()
        let target = directory.appendingPathComponent("private-data")
        try Data("not audio".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: journal.directory.appendingPathComponent("000000.pcm"), withDestinationURL: target)
        let result = RecordingRecovery.recoverAll(in: directory)
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertEqual(try Data(contentsOf: target), Data("not audio".utf8))
    }

    func testUnexpectedFilesAreNeverDeletedByRecovery() throws {
        let journal = try journal()
        journal.retainForRecovery()
        let notes = journal.directory.appendingPathComponent("notes.txt")
        try Data("keep this".utf8).write(to: notes)
        let result = RecordingRecovery.recoverAll(in: directory)
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertEqual(try Data(contentsOf: notes), Data("keep this".utf8))
    }

    func testUnknownManifestPreservesJournal() throws {
        let journal = try journal()
        try journal.append([0.1])
        journal.retainForRecovery()
        try Data("{}".utf8).write(to: journal.directory.appendingPathComponent("session.json"))
        XCTAssertFalse(RecordingRecovery.recoverAll(in: directory).errors.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.directory.path))
    }

    func testEmptyStartupJournalCanBeCleaned() throws {
        let journal = try journal()
        journal.retainForRecovery()
        let result = RecordingRecovery.recoverAll(in: directory)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertTrue(try RecordingRecovery.pending(in: directory).isEmpty)
    }

    /// Launched only by testSIGKILLRecovery below; no device access occurs.
    func testCrashFixture() throws {
        guard let root = ProcessInfo.processInfo.environment["MEETREC_CRASH_FIXTURE"] else { return }
        let rootURL = URL(fileURLWithPath: root)
        let journal = try RecordingJournal(outputURL: rootURL.appendingPathComponent("call.m4a"))
        try journal.append(Array(repeating: 0.25, count: 48_000))
        try Data("ready".utf8).write(to: rootURL.appendingPathComponent("ready"), options: .atomic)
        // Intentionally leave file descriptors/lock open; parent kills process.
        _ = withExtendedLifetime(journal) { raise(SIGSTOP) }
        XCTFail("Crash fixture unexpectedly resumed")
    }

    func testSIGKILLRecovery() throws {
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["-XCTest", "MeetRecTests.RecordingRecoveryTests/testCrashFixture",
                             Bundle(for: RecordingRecoveryTests.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["MEETREC_CRASH_FIXTURE"] = directory.path
        // A sanitized test bundle must preload TSan in its child xctest too;
        // otherwise dlopen loads interceptors too late and fixture aborts.
        for image in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(image) else { continue }
            let path = String(cString: name)
            if path.contains("libclang_rt.tsan") {
                environment["DYLD_INSERT_LIBRARIES"] = path
                break
            }
        }
        process.environment = environment
        let log = directory.appendingPathComponent("fixture.log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        }
        let marker = directory.appendingPathComponent("ready")
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard FileManager.default.fileExists(atPath: marker.path), process.isRunning else {
            if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            return XCTFail("Fixture failed to write audio: \((try? String(contentsOf: log, encoding: .utf8)) ?? "no output")")
        }
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
        let result = RecordingRecovery.recoverAll(in: directory)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let audio = try AVAudioFile(forReading: XCTUnwrap(result.files.first))
        XCTAssertEqual(audio.length, 48_000)
    }
}

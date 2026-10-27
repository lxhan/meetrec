import XCTest
import AVFoundation
@testable import MeetRec

private final class Events {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ value: String) { lock.withLock { items.append(value) } }
    var values: [String] { lock.withLock { items } }
}

private final class FakeSystem: SystemCapturing {
    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    var onFailure: ((Error) -> Void)?
    var startError: Error?
    let events: Events
    init(_ events: Events) { self.events = events }
    func start() async throws {
        events.add("system.start")
        if let startError { throw startError }
    }
    func stop() async { events.add("system.stop") }
}

private final class FakeMic: MicrophoneCapturing {
    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    var onFailure: ((Error) -> Void)?
    var delay: UInt64 = 0
    var stopDelay: TimeInterval = 0
    let events: Events
    init(_ events: Events) { self.events = events }
    func start() async throws {
        events.add("mic.start")
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
    }
    func stop() {
        if stopDelay > 0 { Thread.sleep(forTimeInterval: stopDelay) }
        events.add("mic.stop")
    }
}

private final class FakeWriter: AudioWriting {
    var onFailure: ((Error) -> Void)?
    var finishError: Error?
    let events: Events
    init(_ events: Events) { self.events = events }
    func start() throws { events.add("writer.start") }
    func setMuted(system: Bool, mic: Bool) {}
    func appendSystem(buffer: AVAudioPCMBuffer, time: AVAudioTime) {}
    func appendMic(buffer: AVAudioPCMBuffer, time: AVAudioTime) {}
    func finish() async throws {
        events.add("writer.finish")
        try await Task.sleep(nanoseconds: 20_000_000)
        if let finishError { throw finishError }
    }
}

@MainActor
final class RecordingEngineTests: XCTestCase {
    private var directory: URL!
    private var events: Events!
    private var system: FakeSystem!
    private var mic: FakeMic!
    private var writer: FakeWriter!
    private var engine: RecordingEngine!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        events = Events()
        system = FakeSystem(events)
        mic = FakeMic(events)
        writer = FakeWriter(events)
        let system = self.system!, mic = self.mic!, writer = self.writer!, events = self.events!
        engine = RecordingEngine(directory: directory, makeSystem: { system }, makeMic: { mic },
            makeWriter: { _ in writer }, revealOutput: { _ in events.add("reveal") })
    }

    override func tearDown() async throws {
        await engine.stopAsync()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func waitFor(_ state: RecordingEngine.State) async throws {
        for _ in 0..<1_000 {
            if engine.state == state { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for \(state); got \(engine.state)")
    }

    func testRepeatedStartAndStopAreIdempotent() async throws {
        engine.start()
        engine.start()
        try await waitFor(.recording)
        async let first: Void = engine.stopAsync()
        async let second: Void = engine.stopAsync()
        _ = await (first, second)
        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(events.values.filter { $0 == "writer.start" }.count, 1)
        XCTAssertEqual(events.values.filter { $0 == "writer.finish" }.count, 1)
        let values = events.values
        XCTAssertLessThan(values.firstIndex(of: "system.stop")!, values.firstIndex(of: "writer.finish")!)
        XCTAssertLessThan(values.firstIndex(of: "mic.stop")!, values.firstIndex(of: "writer.finish")!)
        XCTAssertEqual(values.last, "reveal")
    }

    func testShutdownWhileStartingWaitsThenFinalizes() async throws {
        mic.delay = 50_000_000
        engine.start()
        await engine.stopAsync()
        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(events.values.filter { $0 == "writer.finish" }.count, 1)
        XCTAssertTrue(events.values.contains("mic.stop"))
        XCTAssertTrue(events.values.contains("system.stop"))
    }

    func testSystemStartFailureStopsEverythingAndDoesNotClaimSuccess() async throws {
        system.startError = RecordingFailure("system denied")
        engine.start()
        try await waitFor(.failed)
        XCTAssertEqual(engine.lastError, "system denied")
        XCTAssertTrue(events.values.contains("mic.stop"))
        XCTAssertTrue(events.values.contains("writer.finish"))
        XCTAssertFalse(events.values.contains("reveal"))
        XCTAssertNil(engine.lastOutputURL)
    }

    func testRuntimeSourceFailureVisibleAndFinalized() async throws {
        engine.start()
        try await waitFor(.recording)
        system.onFailure?(RecordingFailure("stream disconnected"))
        try await waitFor(.failed)
        XCTAssertEqual(engine.lastError, "stream disconnected")
        XCTAssertTrue(events.values.contains("writer.finish"))
        XCTAssertFalse(events.values.contains("reveal"))
    }

    func testLateFailureFromPreviousSessionCannotStopNewRecording() async throws {
        engine.start()
        try await waitFor(.recording)
        let oldCallback = system.onFailure
        await engine.stopAsync()
        engine.start()
        try await waitFor(.recording)
        oldCallback?(RecordingFailure("stale session error"))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(engine.state, .recording)
        XCTAssertNil(engine.lastError)
    }

    func testWriterFailureStopsSourcesAndRemainsVisible() async throws {
        engine.start()
        try await waitFor(.recording)
        writer.onFailure?(RecordingFailure("encoder failed"))
        try await waitFor(.failed)
        XCTAssertEqual(engine.lastError, "encoder failed")
        XCTAssertTrue(events.values.contains("system.stop"))
        XCTAssertTrue(events.values.contains("mic.stop"))
    }

    func testMicrophoneFailureStopsRecording() async throws {
        engine.start()
        try await waitFor(.recording)
        mic.onFailure?(RecordingFailure("microphone disconnected"))
        try await waitFor(.failed)
        XCTAssertEqual(engine.lastError, "microphone disconnected")
        XCTAssertFalse(events.values.contains("reveal"))
    }

    func testSlowDeviceStopStillFinalizesButRequiresRestart() async throws {
        let system = self.system!, mic = self.mic!, writer = self.writer!
        mic.stopDelay = 0.2
        engine = RecordingEngine(directory: directory, makeSystem: { system }, makeMic: { mic },
            makeWriter: { _ in writer }, shutdownTimeout: 0.01, revealOutput: { _ in })
        engine.start()
        try await waitFor(.recording)
        await engine.stopAsync()
        XCTAssertEqual(engine.state, .failed)
        XCTAssertTrue(engine.requiresRestart)
        XCTAssertTrue(engine.lastError?.contains("Capture may remain active") == true)
        XCTAssertTrue(events.values.contains("writer.finish"))
        engine.start()
        XCTAssertEqual(engine.state, .failed)
        try await Task.sleep(nanoseconds: 250_000_000)
    }

    func testFinishFailureNeverRevealsAsSuccessfulSave() async throws {
        writer.finishError = RecordingFailure("disk full")
        engine.start()
        try await waitFor(.recording)
        await engine.stopAsync()
        XCTAssertEqual(engine.state, .failed)
        XCTAssertEqual(engine.lastError, "disk full")
        XCTAssertFalse(events.values.contains("reveal"))
    }
}

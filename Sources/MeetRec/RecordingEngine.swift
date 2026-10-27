import Foundation
import AVFoundation
import AppKit
import Combine

protocol SystemCapturing: AnyObject {
    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    func start() async throws
    func stop() async
}

protocol MicrophoneCapturing: AnyObject {
    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    func start() async throws
    func stop()
}

protocol AudioWriting: AnyObject {
    var onFailure: ((Error) -> Void)? { get set }
    func start() throws
    func setMuted(system: Bool, mic: Bool)
    func appendSystem(buffer: AVAudioPCMBuffer, time: AVAudioTime)
    func appendMic(buffer: AVAudioPCMBuffer, time: AVAudioTime)
    func finish() async throws
}

extension SystemAudioCapture: SystemCapturing {}
extension MicrophoneCapture: MicrophoneCapturing {}
extension StereoWriter: AudioWriting {}

@MainActor
final class RecordingEngine: ObservableObject {
    enum State: Equatable { case idle, starting, recording, stopping, failed }
    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastError: String?
    @Published private(set) var requiresRestart = false
    @Published private(set) var isRecovering = false
    @Published private(set) var recoveryMessage: String?
    @Published private(set) var lastOutputURL: URL?
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var micLevel: Float = 0
    @Published var systemMuted = false { didSet { updateMute() } }
    @Published var micMuted = false { didSet { updateMute() } }
    var isRecording: Bool { state == .recording }
    var isBusy: Bool { state == .starting || state == .stopping || isRecovering }

    let recordingsDirectory: URL
    private let makeSystem: () -> SystemCapturing
    private let makeMic: () -> MicrophoneCapturing
    private let makeWriter: (URL) throws -> AudioWriting
    private let revealOutput: (URL) -> Void
    private var systemCapture: SystemCapturing?
    private var micCapture: MicrophoneCapturing?
    private var writer: AudioWriting?
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var timer: Timer?
    private var lastToggle = Date.distantPast
    private var startUptime: TimeInterval = 0
    private var lastSystemBuffer: TimeInterval = 0
    private var lastMicBuffer: TimeInterval = 0
    private var healthTicks = 0
    private var sessionID: UUID?
    private var deliveryGate: CaptureDeliveryGate?
    private let shutdownTimeout: Double

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Recordings/MeetRec", isDirectory: true),
         makeSystem: @escaping () -> SystemCapturing = { SystemAudioCapture() },
         makeMic: @escaping () -> MicrophoneCapturing = { MicrophoneCapture() },
         makeWriter: @escaping (URL) throws -> AudioWriting = { try StereoWriter(outputURL: $0) },
         shutdownTimeout: Double = 5,
         revealOutput: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }) {
        recordingsDirectory = directory
        self.makeSystem = makeSystem
        self.makeMic = makeMic
        self.makeWriter = makeWriter
        self.shutdownTimeout = shutdownTimeout
        self.revealOutput = revealOutput
    }

    func recoverInterruptedRecordings() {
        guard !isBusy, !isRecording, startTask == nil, stopTask == nil else { return }
        isRecovering = true
        let directory = recordingsDirectory
        recoveryTask = Task {
            let result = await Task.detached(priority: .utility) {
                RecordingRecovery.recoverAll(in: directory)
            }.value
            var messages: [String] = []
            if !result.files.isEmpty {
                messages.append("Recovered \(result.files.count) interrupted call(s) as playable .caf audio. Open Folder to listen.")
            }
            if !result.errors.isEmpty {
                messages.append("Some recovery files could not be exported and remain on disk: " + result.errors.joined(separator: "; "))
            }
            recoveryMessage = messages.isEmpty ? nil : messages.joined(separator: "\n")
            isRecovering = false
            recoveryTask = nil
        }
    }

    func waitForRecovery() async { await recoveryTask?.value }

    func toggle() {
        guard Date().timeIntervalSince(lastToggle) > 1 else { return }
        lastToggle = Date()
        if isRecording { stop() } else if !isBusy { start() }
    }

    func start() {
        guard !isBusy, !isRecording, !requiresRestart, startTask == nil, stopTask == nil else { return }
        state = .starting
        lastError = nil
        lastOutputURL = nil
        let session = UUID()
        sessionID = session
        startTask = Task {
            await startPipeline(session: session)
            startTask = nil
        }
    }

    private func startPipeline(session: UUID) async {
        do {
            let gate = CaptureDeliveryGate()
            deliveryGate = gate
            let url = try RecordingStorage.outputURL(in: recordingsDirectory)
            let writer = try makeWriter(url)
            self.writer = writer
            writer.onFailure = { [weak self] error in
                Task { @MainActor in self?.reportFailure(error, session: session) }
            }
            updateMute()
            try writer.start()

            let mic = makeMic()
            micCapture = mic // retain before awaiting start, including failed start
            mic.onFailure = { [weak self] error in
                Task { @MainActor in self?.reportFailure(error, session: session) }
            }
            mic.onBuffer = { [weak writer, weak self] buffer, time in
                gate.deliver {
                    writer?.appendMic(buffer: buffer, time: time)
                    let peak = AudioLevel.peak(of: buffer)
                    Task { @MainActor in
                        guard let self, self.sessionID == session else { return }
                        self.lastMicBuffer = ProcessInfo.processInfo.systemUptime
                        self.micLevel = max(self.micLevel, peak)
                    }
                }
            }
            try await mic.start()

            let system = makeSystem()
            systemCapture = system
            system.onFailure = { [weak self] error in
                Task { @MainActor in self?.reportFailure(error, session: session) }
            }
            system.onBuffer = { [weak writer, weak self] buffer, time in
                gate.deliver {
                    writer?.appendSystem(buffer: buffer, time: time)
                    let peak = AudioLevel.peak(of: buffer)
                    Task { @MainActor in
                        guard let self, self.sessionID == session else { return }
                        self.lastSystemBuffer = ProcessInfo.processInfo.systemUptime
                        self.systemLevel = max(self.systemLevel, peak)
                    }
                }
            }
            // Fail closed: never silently substitute mic-only recording.
            try await system.start()
            if let lastError { throw RecordingFailure(lastError) }
            startUptime = ProcessInfo.processInfo.systemUptime
            lastSystemBuffer = startUptime
            lastMicBuffer = startUptime
            healthTicks = 0
            lastOutputURL = url
            state = .recording
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            lastError = error.localizedDescription
            state = .stopping
            await finalize()
            state = .failed
        }
    }

    func stop() { Task { await stopAsync() } }

    /// Idempotent and awaitable. Quit and relaunch use exactly this path,
    /// including when the user is still answering startup permission prompts.
    func stopAsync() async {
        await recoveryTask?.value
        if let stopTask { await stopTask.value; return }
        guard startTask != nil || writer != nil else { return }
        let starting = startTask
        state = .stopping
        let task = Task {
            await starting?.value
            state = .stopping
            await finalize()
            state = lastError == nil ? .idle : .failed
            if lastError == nil, let url = lastOutputURL { revealOutput(url) }
        }
        stopTask = task
        await task.value
        stopTask = nil
    }

    private func finalize() async {
        timer?.invalidate()
        timer = nil
        // Fence delivery before attempting potentially uncooperative OS teardown.
        // Even on a timeout, no capture callback can append after finalization.
        deliveryGate?.close()
        var stopped = true
        if let systemCapture {
            stopped = await CaptureShutdown.wait(seconds: shutdownTimeout) { await systemCapture.stop() }
        }
        if let micCapture {
            let micStopped = await CaptureShutdown.wait(seconds: shutdownTimeout) { micCapture.stop() }
            stopped = stopped && micStopped
        }
        if !stopped {
            requiresRestart = true
            let message = "Audio device shutdown timed out. Capture may remain active until you quit. Quit and relaunch before recording again."
            lastError = lastError.map { $0 + " " + message } ?? message
        }
        if let writer {
            do { try await writer.finish() }
            catch { if lastError == nil { lastError = error.localizedDescription } }
        }
        sessionID = nil
        deliveryGate = nil
        systemCapture = nil
        micCapture = nil
        writer = nil
        elapsed = 0
        systemLevel = 0
        micLevel = 0
    }

    private func updateMute() { writer?.setMuted(system: systemMuted, mic: micMuted) }

    private func reportFailure(_ error: Error, session: UUID? = nil) {
        if let session, session != sessionID { return }
        guard writer != nil, state != .stopping, lastError == nil else { return }
        lastError = error.localizedDescription
        Log.write("recording failed: \(error.localizedDescription)")
        stop()
    }

    private func tick() {
        guard state == .recording else { return }
        let now = ProcessInfo.processInfo.systemUptime
        elapsed = now - startUptime
        systemLevel *= 0.7
        micLevel *= 0.7
        healthTicks += 1
        // Buffer arrival, not amplitude: genuine silence must not trigger an error.
        if now - lastMicBuffer > 5 {
            reportFailure(RecordingFailure("Microphone stopped delivering audio. Recording stopped."))
        }
        // SCK can omit buffers for silent system audio, so do not treat absence
        // alone as an error. Its stream delegate reports actual interruptions.
        if healthTicks % 25 == 0,
           let values = try? recordingsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let free = values.volumeAvailableCapacity, free < 50 * 1_024 * 1_024 {
            reportFailure(RecordingFailure("Less than 50 MB disk space remains. Recording stopped."))
        }
    }
}

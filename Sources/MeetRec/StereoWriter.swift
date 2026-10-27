import Foundation
import AVFoundation

/// All mutable writer/mixer state belongs to queue. Capture timestamps share
/// the host clock; timer cadence never determines the recording's duration.
// Queue-owned state plus locked callback/overload access make cross-thread
// capture submission safe. AVFoundation objects never escape writer queue.
final class StereoWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let outputURL: URL
    private let queue = DispatchQueue(label: "meetrec.stereo-writer", qos: .userInitiated)
    private let pendingBuffers = DispatchSemaphore(value: 256)
    private let overloadLock = NSLock()
    private var overloadReported = false
    private let sampleRate: Double = 48_000
    private let chunkSize = 4_800
    private let latency: Double = 0.25
    private var system = AudioTimeline(capacity: 480_000)
    private var mic = AudioTimeline(capacity: 480_000)
    private var systemConverter: MonoAudioConverter?
    private var micConverter: MonoAudioConverter?
    private var systemMuted = false
    private var micMuted = false
    private let micGain: Float
    private var origin: Double?
    private var timer: DispatchSourceTimer?
    private var failure: Error?
    private var finishing = false
    private var securedFile = false
    private var encodingFailed = false
    private var finishReplied = false
    private var journal: RecordingJournal?
    private let callbackLock = NSLock()
    private var failureHandler: ((Error) -> Void)?
    /// Callback is retrieved under lock and invoked only on writer queue.
    var onFailure: ((Error) -> Void)? {
        get { callbackLock.withLock { failureHandler } }
        set { callbackLock.withLock { failureHandler = newValue } }
    }

    init(outputURL: URL) throws {
        self.outputURL = outputURL
        // AVAssetWriter also refuses existing files. Never unlink one, even
        // when initializing a recording that subsequently fails to start.
        guard !FileManager.default.fileExists(atPath: outputURL.path),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: outputURL.path)) == nil else {
            throw RecordingFailure("Refusing to overwrite existing recording: \(outputURL.lastPathComponent)")
        }
        let db = UserDefaults.standard.double(forKey: "MicGainDb")
        micGain = pow(10, Float(db.isFinite ? min(max(db, -60), 24) : 0) / 20)
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: 128_000
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecordingFailure("Cannot initialize audio encoder.") }
        writer.add(input)
    }

    func start() throws {
        try queue.sync {
            guard writer.status == .unknown else { throw RecordingFailure("Writer already started.") }
            journal = try RecordingJournal(outputURL: outputURL)
            guard writer.startWriting() else {
                journal?.retainForRecovery()
                throw writer.error ?? RecordingFailure("Cannot start recording file.")
            }
            writer.startSession(atSourceTime: .zero)
            let heartbeat = DispatchSource.makeTimerSource(queue: queue)
            heartbeat.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
            heartbeat.setEventHandler { [weak self] in self?.heartbeat() }
            heartbeat.resume()
            timer = heartbeat
        }
    }

    func setMuted(system systemMuted: Bool, mic micMuted: Bool) {
        queue.async { [self] in
            self.systemMuted = systemMuted
            self.micMuted = micMuted
            if systemMuted { system.muteBufferedSamples() }
            if micMuted { mic.muteBufferedSamples() }
        }
    }

    func appendSystem(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        append(buffer: buffer, time: time, isSystem: true)
    }

    func appendMic(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        append(buffer: buffer, time: time, isSystem: false)
    }

    private func append(buffer: AVAudioPCMBuffer, time: AVAudioTime, isSystem: Bool) {
        // Never retain a tap's borrowed memory after its callback returns.
        guard pendingBuffers.wait(timeout: .now()) == .success else {
            overloadLock.lock()
            let report = !overloadReported
            overloadReported = true
            overloadLock.unlock()
            if report {
                queue.async { [self] in fail(RecordingFailure("Audio processing overloaded; recording stopped.")) }
            }
            return
        }
        guard let copy = Self.copyBuffer(buffer) else {
            pendingBuffers.signal()
            queue.async { [self] in fail(RecordingFailure("Cannot copy captured audio.")) }
            return
        }
        queue.async { [self] in
            defer { pendingBuffers.signal() }
            guard failure == nil, !finishing else { return }
            guard time.isHostTimeValid else {
                fail(RecordingFailure("Audio source supplied no host-clock timestamp."))
                return
            }
            let seconds = AVAudioTime.seconds(forHostTime: time.hostTime)
            if origin == nil { origin = seconds }
            let position = Int64(((seconds - origin!) * sampleRate).rounded())
            do {
                let values: [Float]
                if isSystem {
                    if systemConverter?.sourceFormat.isEqual(copy.format) != true {
                        try flushSystemConverter()
                        systemConverter = try MonoAudioConverter(sourceFormat: copy.format)
                    }
                    let delay = systemConverter!.pendingFrames
                    values = try systemConverter!.convert(copy)
                    try system.append(systemMuted ? Array(repeating: 0, count: values.count) : values, at: position - delay)
                } else {
                    if micConverter?.sourceFormat.isEqual(copy.format) != true {
                        try flushMicConverter()
                        micConverter = try MonoAudioConverter(sourceFormat: copy.format)
                    }
                    let delay = micConverter!.pendingFrames
                    values = try micConverter!.convert(copy)
                    try mic.append(micMuted ? Array(repeating: 0, count: values.count) : values, at: position - delay)
                }
            } catch { fail(error) }
        }
    }

    private func heartbeat() {
        guard failure == nil, !finishing, let origin else { return }
        let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let due = Int64(max(0, now - origin - latency) * sampleRate)
        do { try drain(through: due) } catch { fail(error) }
    }

    /// Call only after sources have stopped; all their earlier append blocks
    /// are ahead of this block. Drain the entire tail, not just one chunk.
    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard !finishing else {
                    continuation.resume(throwing: RecordingFailure("Writer already finalized."))
                    return
                }
                finishing = true
                timer?.cancel()
                timer = nil
                // Preserve the encoded prefix if draining fails but the encoder
                // remains usable. Never cancel an otherwise salvageable recording.
                do {
                    try flushSystemConverter()
                    try flushMicConverter()
                    try drain(through: max(system.end, mic.end))
                }
                catch { if failure == nil { failure = error } }
                do {
                    try journal?.seal()
                    guard writer.status == .writing else {
                        throw writer.error ?? failure ?? RecordingFailure("Recording writer stopped unexpectedly.")
                    }
                    input.markAsFinished()
                    let timeout = DispatchWorkItem { [self] in
                        guard !finishReplied else { return }
                        finishReplied = true
                        journal?.retainForRecovery()
                        journal = nil
                        writer.cancelWriting()
                        continuation.resume(throwing: RecordingFailure("Audio encoder finalization timed out. Audio journal retained for recovery."))
                    }
                    queue.asyncAfter(deadline: .now() + .seconds(10), execute: timeout)
                    writer.finishWriting { [self] in
                        queue.async {
                            guard !self.finishReplied else { return }
                            self.finishReplied = true
                            timeout.cancel()
                            do {
                                guard self.writer.status == .completed else {
                                    throw self.writer.error ?? RecordingFailure("Could not finalize recording. Recoverable audio retained.")
                                }
                                if let error = self.failure { throw error }
                                let fd = try RecoveryIO.openExisting(self.outputURL)
                                do { defer { close(fd) }; try RecoveryIO.sync(fd) }
                                let audio = try AVAudioFile(forReading: self.outputURL)
                                let expected = self.journal?.frameCount ?? 0
                                guard audio.length > 0, abs(audio.length - expected) <= 2_048,
                                      audio.fileFormat.sampleRate == 48_000,
                                      audio.fileFormat.channelCount == 2 else {
                                    throw RecordingFailure("Saved audio failed length/format validation; recovery files retained.")
                                }
                                try RecoveryIO.syncDirectory(self.outputURL.deletingLastPathComponent())
                                try self.journal?.discardAfterSuccessfulSave()
                                self.journal = nil
                                continuation.resume()
                            } catch {
                                self.journal?.retainForRecovery()
                                self.journal = nil
                                continuation.resume(throwing: error)
                            }
                        }
                    }
                } catch {
                    journal?.retainForRecovery()
                    journal = nil
                    writer.cancelWriting()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func drain(through end: Int64) throws {
        // A large scheduling gap should not allocate an unbounded silent file.
        guard end - system.cursor <= Int64(system.capacity) else {
            throw RecordingFailure("Audio clock stalled for over 10 seconds; recording stopped.")
        }
        while system.cursor < end {
            let count = Int(min(Int64(chunkSize), end - system.cursor))
            let position = system.cursor
            let sys = system.read(count)
            let own = mic.read(count)
            var mixed = [Float](repeating: 0, count: count * 2)
            var mono = [Float](repeating: 0, count: count)
            for i in 0..<count {
                let value = Self.softClip(sys[i] + own[i] * micGain)
                mono[i] = value
                mixed[2 * i] = value
                mixed[2 * i + 1] = value
            }
            // Journal first: AAC/metadata finalization must never be the sole
            // durable copy. Journal contains exactly the post-mute saved mix.
            try journal?.append(mono)
            if !encodingFailed {
                do {
                    try encode(mixed, frames: count, position: position)
                } catch {
                    encodingFailed = true
                    fail(error)
                    // Keep journaling the remaining accepted audio even if
                    // AAC dies; finish() will retain all segments for recovery.
                }
            }
        }
    }

    private func encode(_ mixed: [Float], frames: Int, position: Int64) throws {
        let buffer = try makeSampleBuffer(mixed, frames: frames, position: position)
        let deadline = DispatchTime.now() + .seconds(2)
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else {
                throw writer.error ?? RecordingFailure("Audio encoder stopped writing.")
            }
            guard DispatchTime.now() < deadline else {
                throw RecordingFailure("Audio encoder stalled; recording stopped.")
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        guard input.append(buffer) else {
            throw writer.error ?? RecordingFailure("Cannot write audio; check available disk space.")
        }
        if !securedFile {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
            securedFile = true
        }
    }

    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        timer?.cancel()
        timer = nil
        Log.write("recording writer failed: \(error.localizedDescription)")
        onFailure?(error)
    }

    static func softClip(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        let knee: Float = 0.95
        let a = abs(value)
        guard a > knee else { return value }
        let squeezed = knee + (1 - knee) * tanh((a - knee) / (1 - knee))
        return value < 0 ? -squeezed : squeezed
    }

    static func copyBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let from = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard from.count == to.count else { return nil }
        for i in 0..<from.count {
            guard let src = from[i].mData, let dst = to[i].mData,
                  from[i].mDataByteSize <= to[i].mDataByteSize else { return nil }
            memcpy(dst, src, Int(from[i].mDataByteSize))
        }
        return copy
    }

    private func flushSystemConverter() throws {
        guard let converter = systemConverter else { return }
        let tail = try converter.finish()
        try system.append(systemMuted ? Array(repeating: 0, count: tail.count) : tail, at: system.end)
        systemConverter = nil
    }

    private func flushMicConverter() throws {
        guard let converter = micConverter else { return }
        let tail = try converter.finish()
        try mic.append(micMuted ? Array(repeating: 0, count: tail.count) : tail, at: mic.end)
        micConverter = nil
    }

    private func makeSampleBuffer(_ values: [Float], frames: Int, position: Int64) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format) == noErr, let format else {
            throw RecordingFailure("Cannot create audio format description.")
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: values.count * 4, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: values.count * 4,
            flags: 0, blockBufferOut: &block) == noErr, let block else {
            throw RecordingFailure("Cannot allocate encoded audio buffer.")
        }
        let copied = values.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                                           offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard copied == noErr else { throw RecordingFailure("Cannot copy audio samples.") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(value: position, timescale: 48_000), decodeTimeStamp: .invalid)
        var size = 8
        var result: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block,
            dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format, sampleCount: frames,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &result) == noErr, let result else {
            throw RecordingFailure("Cannot create audio sample buffer.")
        }
        return result
    }
}

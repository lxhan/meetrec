import Foundation
import AVFoundation
import Darwin

/// Write-ahead, bounded-part PCM journal. It is independent of AAC container
/// finalization: interrupted calls can be recovered even after SIGKILL.
/// Queue-confined by StereoWriter; callers must not share a journal instance.
final class RecordingJournal {
    struct Manifest: Codable {
        let version: Int
        let sampleRate: Int
        let format: String
        let started: Date
        let originalName: String
    }

    static let framesPerPart = 48_000 * 60
    static let rootName = ".recovery"
    let directory: URL
    private var lockFD: Int32 = -1
    private var partFD: Int32 = -1
    private var partIndex = 0
    private var framesInPart = 0
    private var framesSinceSync = 0
    private var sealed = false
    var frameCount: Int64 { Int64(partIndex) * Int64(Self.framesPerPart) + Int64(framesInPart) }

    init(outputURL: URL) throws {
        let root = outputURL.deletingLastPathComponent().appendingPathComponent(Self.rootName, isDirectory: true)
        try RecordingStorage.prepareDirectory(root)
        directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try RecordingStorage.prepareDirectory(directory)
        do {
            lockFD = try RecoveryIO.create(directory.appendingPathComponent("lock"))
            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw RecoveryIO.error("Lock recording journal") }
            let manifest = Manifest(version: 1, sampleRate: 48_000, format: "mono-float32-le",
                                    started: Date(), originalName: outputURL.lastPathComponent)
            let fd = try RecoveryIO.create(directory.appendingPathComponent("session.json"))
            defer { close(fd) }
            try RecoveryIO.write(try JSONEncoder().encode(manifest), to: fd)
            try RecoveryIO.sync(fd)
            try RecoveryIO.syncDirectory(directory)
            try RecoveryIO.syncDirectory(root)
        } catch {
            release()
            throw error
        }
    }

    deinit { release() }

    func append(_ mono: [Float]) throws {
        guard !sealed else { throw RecordingFailure("Recording journal is already closed.") }
        var offset = 0
        while offset < mono.count {
            if partFD < 0 {
                let name = String(format: "%06d.pcm", partIndex)
                partFD = try RecoveryIO.create(directory.appendingPathComponent(name))
                try RecoveryIO.syncDirectory(directory)
            }
            let count = min(mono.count - offset, Self.framesPerPart - framesInPart)
            let data = mono.withUnsafeBytes { bytes in
                Data(bytes[(offset * 4)..<((offset + count) * 4)])
            }
            try RecoveryIO.write(data, to: partFD)
            offset += count
            framesInPart += count
            framesSinceSync += count
            if framesSinceSync >= 48_000 { // durability checkpoint roughly every second
                try RecoveryIO.sync(partFD)
                framesSinceSync = 0
            }
            if framesInPart == Self.framesPerPart {
                try RecoveryIO.sync(partFD)
                close(partFD)
                partFD = -1
                partIndex += 1
                framesInPart = 0
            }
        }
    }

    func seal() throws {
        sealed = true
        if partFD >= 0 {
            try RecoveryIO.sync(partFD)
            close(partFD)
            partFD = -1
        }
    }

    /// Only call after final m4a has completed and been durably synced.
    func discardAfterSuccessfulSave() throws {
        try seal()
        try FileManager.default.removeItem(at: directory)
        release()
    }

    func retainForRecovery() {
        try? seal()
        release()
    }

    private func release() {
        if partFD >= 0 { close(partFD); partFD = -1 }
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
    }
}

enum RecordingRecovery {
    struct Result {
        var files: [URL] = []
        var errors: [String] = []
    }

    static func pending(in recordings: URL) throws -> [URL] {
        let root = recordings.appendingPathComponent(RecordingJournal.rootName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        try RecoveryIO.requireDirectory(root)
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Streaming export to a standard Core Audio File, not a second fragile AAC
    /// session. Source parts stay untouched until destination verifies and syncs.
    static func recoverAll(in recordings: URL) -> Result {
        var result = Result()
        do {
            for directory in try pending(in: recordings) {
                do {
                    if let file = try recover(directory, into: recordings) { result.files.append(file) }
                } catch { result.errors.append("\(directory.lastPathComponent): \(error.localizedDescription)") }
            }
        } catch { result.errors.append(error.localizedDescription) }
        return result
    }

    static func recover(_ directory: URL, into recordings: URL) throws -> URL? {
        try RecoveryIO.requireDirectory(directory)
        let lock = try RecoveryIO.openExisting(directory.appendingPathComponent("lock"), flags: O_RDWR)
        defer { close(lock) }
        if flock(lock, LOCK_EX | LOCK_NB) != 0 {
            if errno == EWOULDBLOCK { return nil } // another live recorder/recovery owns it
            throw RecoveryIO.error("Lock recovery session")
        }
        defer { flock(lock, LOCK_UN) }
        let manifestFD = try RecoveryIO.openExisting(directory.appendingPathComponent("session.json"))
        let manifestData: Data
        do {
            defer { close(manifestFD) }
            manifestData = try RecoveryIO.read(manifestFD, limit: 4_096)
        }
        let manifest = try JSONDecoder().decode(RecordingJournal.Manifest.self, from: manifestData)
        guard manifest.version == 1, manifest.sampleRate == 48_000, manifest.format == "mono-float32-le" else {
            throw RecordingFailure("Unknown recovery audio format; original files retained.")
        }
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        func isPart(_ url: URL) -> Bool {
            url.lastPathComponent.range(of: #"^\d{6}\.pcm$"#, options: .regularExpression) != nil
        }
        let knownNames: Set<String> = ["lock", "session.json", "export.partial.caf", ".DS_Store"]
        guard entries.allSatisfy({ isPart($0) || knownNames.contains($0.lastPathComponent) }) else {
            throw RecordingFailure("Unknown files in recovery session; nothing deleted.")
        }
        let parts = entries.filter(isPart).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var sizes: [Int64] = []
        var total: Int64 = 0
        for (index, part) in parts.enumerated() {
            guard part.lastPathComponent == String(format: "%06d.pcm", index) else {
                throw RecordingFailure("Missing recovery segment; original files retained.")
            }
            let fd = try RecoveryIO.openExisting(part)
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_size <= Int64(RecordingJournal.framesPerPart * 4) else {
                throw RecordingFailure("Invalid recovery segment size.")
            }
            // A process may die in the middle of a Float32 write. Ignore only
            // the trailing incomplete frame of the final part.
            let size = Int64(info.st_size) / 4 * 4
            guard index == parts.count - 1 || size == Int64(RecordingJournal.framesPerPart * 4) else {
                throw RecordingFailure("Truncated non-final recovery segment; files retained.")
            }
            sizes.append(size)
            total += size
        }
        guard total > 0 else {
            // A failed startup with no captured audio has nothing to recover.
            try FileManager.default.removeItem(at: directory)
            return nil
        }
        try RecordingStorage.prepareDirectory(recordings)
        let output = recordings.appendingPathComponent("Recovered_\(UUID().uuidString).caf")
        let temporary = directory.appendingPathComponent("export.partial.caf")
        // A killed export can leave its partial copy, never a source segment.
        // Removing this known derived file is safe; raw .pcm parts stay intact.
        if FileManager.default.fileExists(atPath: temporary.path) ||
            (try? FileManager.default.destinationOfSymbolicLink(atPath: temporary.path)) != nil {
            try FileManager.default.removeItem(at: temporary)
        }
        let out = try RecoveryIO.create(temporary)
        var fdOpen = true
        defer {
            if fdOpen { close(out) }
            try? FileManager.default.removeItem(at: temporary)
        }
        try RecoveryIO.write(cafHeader(audioBytes: total), to: out)
        for (index, part) in parts.enumerated() {
            let fd = try RecoveryIO.openExisting(part)
            defer { close(fd) }
            var remaining = sizes[index]
            while remaining > 0 {
                let chunk = try RecoveryIO.read(fd, limit: Int(min(65_536, remaining)))
                guard !chunk.isEmpty else { throw RecordingFailure("Recovery segment changed while reading.") }
                try RecoveryIO.write(chunk, to: out)
                remaining -= Int64(chunk.count)
            }
        }
        try RecoveryIO.sync(out)
        close(out)
        fdOpen = false
        // Actual decoder validation, not just checking that a file exists.
        let audio = try AVAudioFile(forReading: temporary)
        guard audio.length == total / 4, audio.processingFormat.sampleRate == 48_000,
              audio.processingFormat.channelCount == 1 else {
            throw RecordingFailure("Recovered audio failed validation; original segments retained.")
        }
        // Hard link atomically refuses an existing destination. Both files are
        // on the same volume; source journal is deleted only after publication.
        guard link(temporary.path, output.path) == 0 else { throw RecoveryIO.error("Publish recovered audio") }
        try RecoveryIO.syncDirectory(recordings)
        try FileManager.default.removeItem(at: directory)
        return output
    }

    static func cafHeader(audioBytes: Int64) -> Data {
        var data = Data("caff".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var big = value.bigEndian
            withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
        }
        append(UInt16(1)); append(UInt16(0))
        data.append(Data("desc".utf8)); append(Int64(32))
        append(Double(48_000).bitPattern)
        data.append(Data("lpcm".utf8))
        append(UInt32(3)) // Float32, little endian (CAF-specific format flags)
        append(UInt32(4)); append(UInt32(1)); append(UInt32(1)); append(UInt32(32))
        data.append(Data("data".utf8)); append(audioBytes + 4); append(UInt32(0))
        return data
    }
}

enum RecoveryIO {
    static func error(_ action: String) -> Error {
        let code = errno
        return RecordingFailure("\(action): \(String(cString: strerror(code)))")
    }

    static func requireDirectory(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw RecordingFailure("Recovery path must not be a symbolic link.")
        }
    }

    static func create(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw error("Create private recording file") }
        return fd
    }

    static func openExisting(_ url: URL, flags: Int32 = O_RDONLY) throws -> Int32 {
        let fd = open(url.path, flags | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw error("Open recovery file") }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw RecordingFailure("Recovery file must be a regular file.")
        }
        return fd
    }

    static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw error("Write recoverable audio") }
                offset += count
            }
        }
    }

    static func read(_ fd: Int32, limit: Int) throws -> Data {
        var data = Data(count: limit)
        let count: Int = try data.withUnsafeMutableBytes { bytes in
            while true {
                let count = Darwin.read(fd, bytes.baseAddress!, limit)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw error("Read recovery audio") }
                return count
            }
        }
        data.count = count
        return data
    }

    static func sync(_ fd: Int32) throws {
        while fsync(fd) != 0 {
            if errno != EINTR { throw error("Sync recording to disk") }
        }
    }

    static func syncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw error("Open recording directory") }
        defer { close(fd) }
        try sync(fd)
    }
}

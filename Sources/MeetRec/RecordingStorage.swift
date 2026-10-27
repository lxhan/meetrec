import Foundation

/// Never reuse an output name or remove an existing recording.
enum RecordingStorage {
    static func prepareDirectory(_ url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw RecordingFailure("Recording directory must be a real directory, not a symbolic link.")
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func outputURL(in directory: URL, date: Date = Date()) throws -> URL {
        try prepareDirectory(directory)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return directory.appendingPathComponent("\(formatter.string(from: date))_\(UUID().uuidString).m4a")
    }
}

struct RecordingFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

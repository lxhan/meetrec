import Foundation

/// Closing this gate fences all callbacks already handing audio to the writer.
/// Slow/hung hardware teardown can no longer prevent the file being finalized.
final class CaptureDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true

    func deliver(_ action: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if open { action() }
    }

    func close() { lock.withLock { open = false } }
}

private final class ShutdownRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

    func resolve(_ result: Bool) {
        let continuation = lock.withLock {
            let saved = self.continuation
            self.continuation = nil
            return saved
        }
        continuation?.resume(returning: result)
    }
}

enum CaptureShutdown {
    /// Do not use a task group here: its scope would still wait for an
    /// uncooperative CoreAudio stop even after cancellation/timeout.
    static func wait(seconds: Double, operation: @escaping () async -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            let race = ShutdownRace(continuation)
            Task.detached {
                await operation()
                race.resolve(true)
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                race.resolve(false)
            }
        }
    }
}

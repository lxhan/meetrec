import Foundation

/// Fixed-size timestamp-indexed ring. Silence fills gaps; stale frames cannot
/// shift later speech backwards. Overload fails explicitly instead of growing RAM.
struct AudioTimeline {
    private var samples: [Float]
    private var tags: [Int64]
    private(set) var cursor: Int64 = 0
    private(set) var end: Int64 = 0
    var capacity: Int { samples.count }

    init(capacity: Int) {
        precondition(capacity > 0)
        samples = Array(repeating: 0, count: capacity)
        tags = Array(repeating: -1, count: capacity)
    }

    mutating func append(_ values: [Float], at start: Int64) throws {
        let limit = start + Int64(values.count)
        guard limit <= cursor + Int64(capacity) else {
            throw RecordingFailure("Audio buffer exceeded its limit. Recording stopped to avoid silent data loss.")
        }
        guard limit > cursor else { return }
        for frame in max(cursor, start)..<limit {
            let slot = Int(frame % Int64(capacity))
            samples[slot] = values[Int(frame - start)]
            tags[slot] = frame
        }
        end = max(end, limit)
    }

    mutating func read(_ count: Int) -> [Float] {
        precondition(count >= 0 && count <= capacity)
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let frame = cursor + Int64(i)
            let slot = Int(frame % Int64(capacity))
            if tags[slot] == frame { result[i] = samples[slot] }
            tags[slot] = -1
        }
        cursor += Int64(count)
        return result
    }

    mutating func muteBufferedSamples() {
        samples = Array(repeating: 0, count: capacity)
    }
}

import AVFoundation

/// Honors AVAudioConverter's requested input packet count and drains every
/// output chunk. Supplying one oversized buffer once can silently drop its tail.
final class MonoAudioConverter {
    let sourceFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private var inputFrames: Int64 = 0
    private var emittedFrames: Int64 = 0
    /// Output delayed inside the sample-rate converter belongs before the next
    /// input timestamp, not after it. Account for this when placing samples.
    var pendingFrames: Int64 {
        guard converter != nil else { return 0 }
        return max(0, Int64((Double(inputFrames) * 48_000 / sourceFormat.sampleRate).rounded()) - emittedFrames)
    }
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                       channels: 1, interleaved: false)!

    init(sourceFormat: AVAudioFormat) throws {
        self.sourceFormat = sourceFormat
        if sourceFormat.commonFormat == .pcmFormatFloat32 && sourceFormat.sampleRate == 48_000 {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: sourceFormat, to: target) else {
                throw RecordingFailure("Unsupported captured audio format.")
            }
            converter.primeMethod = .normal
            self.converter = converter
        }
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> [Float] {
        guard let converter else {
            let frames = Int(input.frameLength), channels = Int(input.format.channelCount)
            guard channels > 0, let data = input.floatChannelData else {
                throw RecordingFailure("Invalid Float32 capture buffer.")
            }
            var mono = [Float](repeating: 0, count: frames)
            for i in 0..<frames {
                for c in 0..<channels {
                    mono[i] += input.format.isInterleaved ? data[0][i * channels + c] : data[c][i]
                }
                mono[i] /= Float(channels)
            }
            return mono
        }
        var offset: AVAudioFrameCount = 0
        var inputError: Error?
        let values = try drain(converter) { requested, state in
            guard offset < input.frameLength else { state.pointee = .noDataNow; return nil }
            let count = min(AVAudioFrameCount(requested), input.frameLength - offset)
            guard count > 0, let slice = Self.slice(input, offset: offset, count: count) else {
                inputError = RecordingFailure("Cannot prepare converter input.")
                state.pointee = .noDataNow
                return nil
            }
            offset += count
            state.pointee = .haveData
            return slice
        }
        if let inputError { throw inputError }
        guard offset == input.frameLength else { throw RecordingFailure("Audio converter did not consume captured samples.") }
        inputFrames += Int64(input.frameLength)
        emittedFrames += Int64(values.count)
        return values
    }

    func finish() throws -> [Float] {
        guard let converter else { return [] }
        let values = try drain(converter) { _, state in state.pointee = .endOfStream; return nil }
        emittedFrames += Int64(values.count)
        return values
    }

    private func drain(_ converter: AVAudioConverter, input: @escaping AVAudioConverterInputBlock) throws -> [Float] {
        var values: [Float] = []
        for _ in 0..<1_024 {
            let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4_096)!
            var error: NSError?
            let status = converter.convert(to: out, error: &error, withInputFrom: input)
            if let error { throw error }
            guard status != .error, let data = out.floatChannelData?[0] else {
                throw RecordingFailure("Audio conversion failed.")
            }
            values.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
            if status == .inputRanDry || status == .endOfStream { return values }
        }
        throw RecordingFailure("Audio converter exceeded safe processing limit.")
    }

    private static func slice(_ source: AVAudioPCMBuffer, offset: AVAudioFrameCount,
                              count: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let result = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: count) else { return nil }
        result.frameLength = count
        let from = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let to = UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList)
        let bytesPerFrame = Int(source.format.streamDescription.pointee.mBytesPerFrame)
        let byteOffset = Int(offset) * bytesPerFrame
        let byteCount = Int(count) * bytesPerFrame
        guard from.count == to.count else { return nil }
        for i in 0..<from.count {
            guard let src = from[i].mData, let dst = to[i].mData,
                  byteOffset + byteCount <= Int(from[i].mDataByteSize),
                  byteCount <= Int(to[i].mDataByteSize) else { return nil }
            memcpy(dst, src.advanced(by: byteOffset), byteCount)
        }
        return result
    }
}

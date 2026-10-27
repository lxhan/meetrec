import XCTest
import AVFoundation
@testable import MeetRec

final class MonoAudioConverterTests: XCTestCase {
    func testLarge48kBufferNeverDropsTail() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9_600)!
        buffer.frameLength = 9_600
        for i in 0..<9_600 { buffer.floatChannelData![0][i] = Float(i) / 10_000 }
        let converter = try MonoAudioConverter(sourceFormat: format)
        let values = try converter.convert(buffer) + converter.finish()
        XCTAssertEqual(values.count, 9_600)
        XCTAssertEqual(values.last, 0.9599)
    }

    func testInterleavedStereoDownmix() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                   channels: 2, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2)!
        buffer.frameLength = 2
        let data = buffer.floatChannelData![0]
        data[0] = 0.2; data[1] = 0.6; data[2] = -0.5; data[3] = 0.5
        let values = try MonoAudioConverter(sourceFormat: format).convert(buffer)
        XCTAssertEqual(values[0], 0.4, accuracy: 0.00001)
        XCTAssertEqual(values[1], 0)
    }

    func testResamplingSingleLargeBufferConsumesAllPackets() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        buffer.frameLength = 44_100
        for i in 0..<44_100 { buffer.floatChannelData![0][i] = 0.25 }
        let converter = try MonoAudioConverter(sourceFormat: format)
        let values = try converter.convert(buffer) + converter.finish()
        XCTAssertLessThanOrEqual(abs(values.count - 48_000), 2)
        XCTAssertEqual(values[24_000], 0.25, accuracy: 0.002)
    }

    func testStreamingResamplingFlushesFinalTail() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let converter = try MonoAudioConverter(sourceFormat: format)
        var samples: [Float] = []
        for _ in 0..<100 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441)!
            buffer.frameLength = 441
            for i in 0..<441 { buffer.floatChannelData![0][i] = 0.1 }
            samples.append(contentsOf: try converter.convert(buffer))
        }
        samples.append(contentsOf: try converter.finish())
        XCTAssertLessThanOrEqual(abs(samples.count - 48_000), 2)
    }

    func testNonFloat32ConversionDoesNotDropLargeInputTail() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                                   channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9_600)!
        buffer.frameLength = 9_600
        for i in 0..<9_600 { buffer.int16ChannelData![0][i] = 8_192 }
        let converter = try MonoAudioConverter(sourceFormat: format)
        let values = try converter.convert(buffer) + converter.finish()
        XCTAssertEqual(values.count, 9_600)
        XCTAssertEqual(try XCTUnwrap(values.last), 0.25, accuracy: 0.0001)
    }
}

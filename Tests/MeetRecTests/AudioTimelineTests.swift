import XCTest
@testable import MeetRec

final class AudioTimelineTests: XCTestCase {
    func testGapRemainsSilenceRatherThanMovingSpeech() throws {
        var timeline = AudioTimeline(capacity: 16)
        try timeline.append([1, 2], at: 3)
        XCTAssertEqual(timeline.read(6), [0, 0, 0, 1, 2, 0])
    }

    func testLateFramesAreTrimmed() throws {
        var timeline = AudioTimeline(capacity: 8)
        _ = timeline.read(3)
        try timeline.append([1, 2, 3, 4, 5], at: 0)
        XCTAssertEqual(timeline.read(3), [4, 5, 0])
        try timeline.append([99], at: 0)
        XCTAssertEqual(timeline.read(1), [0])
    }

    func testWrapDoesNotReplayStaleAudio() throws {
        var timeline = AudioTimeline(capacity: 4)
        try timeline.append([1, 2, 3, 4], at: 0)
        XCTAssertEqual(timeline.read(4), [1, 2, 3, 4])
        try timeline.append([7], at: 6)
        XCTAssertEqual(timeline.read(4), [0, 0, 7, 0])
    }

    func testOverflowFailsWithoutUnboundedGrowth() throws {
        var timeline = AudioTimeline(capacity: 4)
        XCTAssertThrowsError(try timeline.append([1], at: 4))
        XCTAssertEqual(timeline.end, 0)
        XCTAssertEqual(timeline.capacity, 4)
    }

    func testMuteClearsAlreadyBufferedAudio() throws {
        var timeline = AudioTimeline(capacity: 4)
        try timeline.append([1, 2, 3], at: 0)
        timeline.muteBufferedSamples()
        XCTAssertEqual(timeline.read(3), [0, 0, 0])
    }

    func testNegativeOffsetTrimsFramesBeforeOrigin() throws {
        var timeline = AudioTimeline(capacity: 4)
        try timeline.append([1, 2, 3], at: -2)
        XCTAssertEqual(timeline.read(2), [3, 0])
    }
}

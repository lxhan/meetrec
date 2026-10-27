import XCTest
@testable import MeetRec

final class CaptureShutdownTests: XCTestCase {
    func testClosedGateRejectsLateDelivery() {
        let gate = CaptureDeliveryGate()
        var deliveries = 0
        gate.deliver { deliveries += 1 }
        gate.close()
        gate.deliver { deliveries += 1 }
        XCTAssertEqual(deliveries, 1)
    }

    func testFastShutdownSucceeds() async {
        let stopped = await CaptureShutdown.wait(seconds: 1) {}
        XCTAssertTrue(stopped)
    }

    func testTimeoutDoesNotWaitForUncooperativeOperation() async throws {
        let completed = expectation(description: "slow shutdown eventually returns")
        let before = ProcessInfo.processInfo.systemUptime
        let stopped = await CaptureShutdown.wait(seconds: 0.01) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            completed.fulfill()
        }
        XCTAssertFalse(stopped)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - before, 0.15)
        // Also verify late completion cannot resume the continuation twice.
        await fulfillment(of: [completed], timeout: 2)
    }
}

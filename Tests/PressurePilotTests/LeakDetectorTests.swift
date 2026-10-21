import XCTest
@testable import PressurePilot

final class LeakDetectorTests: XCTestCase {
    private let mb: UInt64 = 1 << 20
    private let gb: UInt64 = 1 << 30

    func testSteadyGrowthWithJitterIsLeak() throws {
        // 1 GB -> 3 GB over two hours, plus up to 120 MB of jitter.
        let samples = (0..<120).map { gb + UInt64($0) * (2 * gb / 120) + UInt64($0 % 7) * 20 * mb }
        let rate = try XCTUnwrap(LeakDetector.growthPerHour(samples))
        XCTAssertEqual(Double(rate) / Double(gb), 1.0, accuracy: 0.15)
    }

    func testSawtoothIsNotLeak() {
        // Typical garbage-collected app: grows, collects, grows again.
        let samples = (0..<120).map { 2 * gb + UInt64($0 % 20) * 50 * mb }
        XCTAssertNil(LeakDetector.growthPerHour(samples))
    }

    func testGrowthThatIsReleasedIsNotLeak() {
        let samples = (0..<120).map { $0 < 100 ? gb + UInt64($0) * 20 * mb : gb }
        XCTAssertNil(LeakDetector.growthPerHour(samples))
    }

    func testSmallGrowthIsNotLeak() {
        let samples = (0..<120).map { gb + UInt64($0) * mb }
        XCTAssertNil(LeakDetector.growthPerHour(samples))
    }

    func testNeedsAtLeastAnHourOfSamples() {
        let samples = (0..<59).map { gb + UInt64($0) * 100 * mb }
        XCTAssertNil(LeakDetector.growthPerHour(samples))
    }
}

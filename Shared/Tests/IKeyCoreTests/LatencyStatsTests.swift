import XCTest
@testable import IKeyCore

final class LatencyStatsTests: XCTestCase {
    func testPercentiles() {
        var stats = LatencyStats()
        XCTAssertEqual(stats.count, 0)
        XCTAssertNil(stats.percentile(50))
        stats.add(0.010)
        XCTAssertEqual(stats.percentile(0), 0.010)
        XCTAssertEqual(stats.percentile(50), 0.010)
        XCTAssertEqual(stats.percentile(100), 0.010)

        stats = LatencyStats()
        // 1...20 ms, added out of order.
        for ms in [7, 3, 20, 1, 15, 9, 12, 18, 2, 5, 11, 4, 16, 6, 19, 8, 14, 10, 17, 13] {
            stats.add(Double(ms) / 1000)
        }
        XCTAssertEqual(stats.count, 20)
        // Nearest rank: ceil(p/100 * n).
        XCTAssertEqual(stats.percentile(50), 0.010)
        XCTAssertEqual(stats.percentile(95), 0.019)
        XCTAssertEqual(stats.percentile(96), 0.020)
        XCTAssertEqual(stats.percentile(5), 0.001)
        XCTAssertEqual(stats.percentile(5.1), 0.002)
        XCTAssertEqual(stats.percentile(0), 0.001)
        XCTAssertEqual(stats.percentile(100), 0.020)
        XCTAssertEqual(stats.percentile(-10), 0.001, "clamped")
        XCTAssertEqual(stats.percentile(250), 0.020, "clamped")
        XCTAssertNil(stats.percentile(.nan))

        // Invalid samples are ignored.
        stats.add(.nan)
        stats.add(.infinity)
        stats.add(-0.001)
        XCTAssertEqual(stats.count, 20)
    }

    func testRingWraps() {
        var stats = LatencyStats(capacity: 4)
        for ms in 1...4 { stats.add(Double(ms)) }
        XCTAssertEqual(stats.count, 4)
        XCTAssertEqual(stats.percentile(0), 1)
        // The oldest samples are replaced first.
        stats.add(100)
        stats.add(200)
        XCTAssertEqual(stats.count, 4)
        XCTAssertEqual(stats.percentile(0), 3)
        XCTAssertEqual(stats.percentile(100), 200)
        for _ in 0..<10 { stats.add(50) }
        XCTAssertEqual(stats.count, 4)
        XCTAssertEqual(stats.percentile(0), 50)
        XCTAssertEqual(stats.percentile(100), 50)

        var single = LatencyStats(capacity: 0)
        single.add(1)
        single.add(2)
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single.percentile(50), 2)

        XCTAssertEqual(LatencyStats().count, 0)
        var full = LatencyStats()
        for i in 0..<100 { full.add(Double(i)) }
        XCTAssertEqual(full.count, 64, "default capacity")
        XCTAssertEqual(full.percentile(0), 36)
    }
}

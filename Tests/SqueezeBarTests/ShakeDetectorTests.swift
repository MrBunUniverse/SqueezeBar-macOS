import XCTest
@testable import SqueezeBar

final class ShakeDetectorTests: XCTestCase {
    func testRealShakeFires() {
        var detector = ShakeDetector()
        XCTAssertFalse(detector.add(point: CGPoint(x: 500, y: 400), time: 0.00))
        XCTAssertFalse(detector.add(point: CGPoint(x: 545, y: 402), time: 0.06))
        XCTAssertFalse(detector.add(point: CGPoint(x: 500, y: 401), time: 0.14)) // reversal 1
        XCTAssertFalse(detector.add(point: CGPoint(x: 548, y: 399), time: 0.22)) // reversal 2
        XCTAssertTrue(detector.add(point: CGPoint(x: 502, y: 400), time: 0.30))  // reversal 3
    }

    func testSlowWiggleDoesNotFire() {
        var detector = ShakeDetector()
        XCTAssertFalse(detector.add(point: CGPoint(x: 500, y: 400), time: 0.00))
        XCTAssertFalse(detector.add(point: CGPoint(x: 550, y: 400), time: 0.25))
        XCTAssertFalse(detector.add(point: CGPoint(x: 500, y: 400), time: 0.60)) // reversal 1
        XCTAssertFalse(detector.add(point: CGPoint(x: 550, y: 400), time: 0.95)) // reversal 2
        XCTAssertFalse(detector.add(point: CGPoint(x: 500, y: 400), time: 1.30)) // reversal 3, outside 0.6 s window
        XCTAssertFalse(detector.add(point: CGPoint(x: 550, y: 400), time: 1.65)) // reversal 4, still outside 0.6 s
    }

    func testSmallJitterUnder30PtDoesNotFire() {
        var detector = ShakeDetector()
        let xs: [CGFloat] = [500, 520, 496, 518, 498, 522, 497, 519, 499]
        for (idx, x) in xs.enumerated() {
            XCTAssertFalse(detector.add(point: CGPoint(x: x, y: 400), time: Double(idx) * 0.04))
        }
    }

    func testLongStraightDragDoesNotFire() {
        var detector = ShakeDetector()
        for step in 0...25 {
            let x = CGFloat(100 + step * 35)
            let y = CGFloat(400 + step * 4)
            XCTAssertFalse(detector.add(point: CGPoint(x: x, y: y), time: Double(step) * 0.02))
        }
    }

    func testFiresOnlyOncePerDrag() {
        var detector = ShakeDetector()
        XCTAssertFalse(detector.add(point: CGPoint(x: 300, y: 300), time: 0.00))
        XCTAssertFalse(detector.add(point: CGPoint(x: 345, y: 300), time: 0.05))
        XCTAssertFalse(detector.add(point: CGPoint(x: 300, y: 300), time: 0.10))
        XCTAssertFalse(detector.add(point: CGPoint(x: 345, y: 300), time: 0.15))
        XCTAssertTrue(detector.add(point: CGPoint(x: 300, y: 300), time: 0.20))

        // Continuing to shake during the same drag must not fire again.
        XCTAssertFalse(detector.add(point: CGPoint(x: 345, y: 300), time: 0.25))
        XCTAssertFalse(detector.add(point: CGPoint(x: 300, y: 300), time: 0.30))
        XCTAssertFalse(detector.add(point: CGPoint(x: 345, y: 300), time: 0.35))
        XCTAssertFalse(detector.add(point: CGPoint(x: 300, y: 300), time: 0.40))
    }
}

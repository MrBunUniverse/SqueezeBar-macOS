import XCTest
@testable import SqueezeBar

final class LiquidPillDetentTests: XCTestCase {
    func testHysteresisInBothDirections() {
        let centers: [CGFloat] = [0, 40, 100]
        XCTAssertEqual(liquidPillDetentIndex(at: 0, centers: centers, current: 0), 0)
        XCTAssertEqual(liquidPillDetentIndex(at: 23.9, centers: centers, current: 0), 0)
        XCTAssertEqual(liquidPillDetentIndex(at: 24, centers: centers, current: 0), 1)
        XCTAssertEqual(liquidPillDetentIndex(at: 17, centers: centers, current: 1), 1)
        XCTAssertEqual(liquidPillDetentIndex(at: 16, centers: centers, current: 1), 0)
        XCTAssertEqual(liquidPillDetentIndex(at: 73.9, centers: centers, current: 1), 1)
        XCTAssertEqual(liquidPillDetentIndex(at: 74, centers: centers, current: 1), 2)
        XCTAssertEqual(liquidPillDetentIndex(at: 66, centers: centers, current: 2), 1)
    }

    func testDragCancelsPendingArrival() {
        for animated in [true, false] {
            var arrivals = 0
            let sim = LiquidPillSim(onArrival: { arrivals += 1 })
            let target = CGRect(x: 0, y: 0, width: 40, height: 26)
            sim.update(target: target, drag: nil, at: 0)
            sim.selectionChanged(animated: true)
            sim.cancelArrival()
            sim.update(target: target, drag: nil, at: 1)
            sim.advance(to: 2)
            XCTAssertEqual(arrivals, 0)
            sim.selectionChanged(animated: animated)
            sim.update(target: target.offsetBy(dx: 80, dy: 0), drag: nil, at: 2)
            for frame in 1...240 { sim.advance(to: 2 + Double(frame) / 120) }
            XCTAssertEqual(arrivals, 1)
        }
    }

    func testFastCrossingsAndEndpoints() {
        let centers: [CGFloat] = [0, 40, 100]
        XCTAssertEqual(liquidPillDetentIndex(at: 200, centers: centers, current: 0), 2)
        XCTAssertEqual(liquidPillDetentIndex(at: -100, centers: centers, current: 2), 0)
        XCTAssertEqual(liquidPillDetentIndex(at: 200, centers: [0], current: 0), 0)
        XCTAssertEqual(liquidPillDetentIndex(at: 0, centers: [], current: 0), 0)
    }
}

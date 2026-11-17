import XCTest
@testable import SqueezeBar

@MainActor
final class ShakeToSummonTests: XCTestCase {
    private let screenVisibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 870)

    func testSummonPlacesOrbAwayFromDragDirectionAndNotUnderCursor() {
        let cursor = CGPoint(x: 720, y: 450)

        // Dragging right (+1) places orb to the left of the cursor.
        let originRightDrag = FloatingBallController.summonTargetOrigin(
            cursor: cursor,
            dragDirection: 1,
            visibleFrame: screenVisibleFrame
        )
        let centerRightDrag = CGPoint(
            x: originRightDrag.x + FloatingBallController.panelSize / 2,
            y: originRightDrag.y + FloatingBallController.panelSize / 2
        )
        XCTAssertLessThan(centerRightDrag.x, cursor.x)
        XCTAssertGreaterThanOrEqual(abs(centerRightDrag.x - cursor.x), FloatingBallController.orbSize / 2 + 12)

        // Dragging left (-1) places orb to the right of the cursor.
        let originLeftDrag = FloatingBallController.summonTargetOrigin(
            cursor: cursor,
            dragDirection: -1,
            visibleFrame: screenVisibleFrame
        )
        let centerLeftDrag = CGPoint(
            x: originLeftDrag.x + FloatingBallController.panelSize / 2,
            y: originLeftDrag.y + FloatingBallController.panelSize / 2
        )
        XCTAssertGreaterThan(centerLeftDrag.x, cursor.x)
        XCTAssertGreaterThanOrEqual(abs(centerLeftDrag.x - cursor.x), FloatingBallController.orbSize / 2 + 12)
    }

    func testSummonClampsInsideVisibleFrameAndFlipsAwayFromCursorNearEdge() {
        // Cursor near left edge while dragging right: left side has no room, so it must flip right.
        let cursor = CGPoint(x: 20, y: 450)
        let origin = FloatingBallController.summonTargetOrigin(
            cursor: cursor,
            dragDirection: 1,
            visibleFrame: screenVisibleFrame
        )
        let orbCenter = CGPoint(
            x: origin.x + FloatingBallController.panelSize / 2,
            y: origin.y + FloatingBallController.panelSize / 2
        )
        let orbHalf = FloatingBallController.orbSize / 2
        XCTAssertGreaterThanOrEqual(orbCenter.x - orbHalf, screenVisibleFrame.minX)
        XCTAssertGreaterThan(orbCenter.x - cursor.x, orbHalf)
    }

    func testSummonSkipsMoveWithin150Pt() {
        let orbCenter = CGPoint(x: 1380, y: 450)
        XCTAssertFalse(FloatingBallController.shouldSummonMove(currentOrbCenter: orbCenter, cursor: CGPoint(x: 1290, y: 460)))
        XCTAssertTrue(FloatingBallController.shouldSummonMove(currentOrbCenter: orbCenter, cursor: CGPoint(x: 1100, y: 450)))
    }

    func testSummonSpringArrivesAround04sAndSettlesWithin08s() {
        let curve = BallGlideCurve.summonSpring
        XCTAssertLessThanOrEqual(curve.duration, 0.8)
        let at04 = curve.sample(at: 0.40)
        XCTAssertEqual(at04.positionProgress, 1.0, accuracy: 0.05)
        let atEnd = curve.sample(at: curve.duration)
        XCTAssertTrue(atEnd.isSettled)
        XCTAssertEqual(atEnd.positionProgress, 1.0, accuracy: 0.0001)
    }

    func testReduceMotionCrossFadeMidpointSwap() {
        let curve = BallGlideCurve.reduceMotionDefault
        let early = curve.sample(at: curve.duration * 0.25)
        XCTAssertEqual(early.positionProgress, 0.0)
        XCTAssertEqual(early.alpha, 0.5, accuracy: 0.01)
        XCTAssertFalse(early.isSettled)

        let late = curve.sample(at: curve.duration * 0.75)
        XCTAssertEqual(late.positionProgress, 1.0)
        XCTAssertEqual(late.alpha, 0.5, accuracy: 0.01)
        XCTAssertFalse(late.isSettled)

        let done = curve.sample(at: curve.duration)
        XCTAssertTrue(done.isSettled)
        XCTAssertEqual(done.alpha, 1.0)
        XCTAssertEqual(done.positionProgress, 1.0)
    }
    func testMagnetField() {
        let anchor = CGPoint.zero
        let center = CGPoint(x: 80, y: 80)
        func target(_ distance: CGFloat) -> CGPoint {
            FloatingBallController.magnetTarget(anchor: anchor, cursor: CGPoint(x: center.x + distance, y: center.y))
        }
        XCTAssertEqual(target(200), anchor)
        XCTAssertEqual(target(160), anchor)
        var previous: CGFloat = 0
        for distance in stride(from: CGFloat(159), through: 1, by: -1) {
            let right = target(distance), left = target(-distance)
            XCTAssertGreaterThanOrEqual(right.x, previous)
            XCTAssertLessThanOrEqual(right.x, FloatingBallController.maxDrift)
            XCTAssertEqual(right.x, -left.x, accuracy: 0.00001)
            previous = right.x
        }
    }

    func testMagnetSpringSettlesAndBecomesIdle() {
        for rate in [60.0, 120.0] {
            var position = CGPoint.zero
            var velocity = CGVector.zero
            let target = CGPoint(x: 28, y: 0)
            var settledAt: Double?
            for frame in 1...Int(rate * 0.6) {
                (position, velocity) = FloatingBallController.springStep(
                    position: position, velocity: velocity, target: target, dt: 1 / rate)
                if position == target && velocity == .zero {
                    settledAt = Double(frame) / rate
                    break
                }
            }
            XCTAssertNotNil(settledAt)
            XCTAssertLessThan(settledAt ?? 1, 0.6)
            let idle = FloatingBallController.springStep(position: position, velocity: velocity, target: target, dt: 1 / rate)
            XCTAssertEqual(idle.0, target)
            XCTAssertEqual(idle.1, .zero)
        }
    }

    func testMagnetRetargetPreservesVelocity() {
        let first = FloatingBallController.springStep(position: .zero, velocity: .zero,
                                                      target: CGPoint(x: 28, y: 0), dt: 1 / 120)
        let next = FloatingBallController.springStep(position: first.0, velocity: first.1,
                                                     target: CGPoint(x: 27, y: 0), dt: 1 / 120)
        XCTAssertGreaterThan(next.1.dx, first.1.dx)
        XCTAssertGreaterThan(next.1.dx, 28 * 170 / 120)
    }

    func testMagnetSpringClampsLongFrameDelta() {
        let target = CGPoint(x: 28, y: -12)
        let long = FloatingBallController.springStep(position: .zero, velocity: .zero, target: target, dt: 1)
        let clamped = FloatingBallController.springStep(position: .zero, velocity: .zero, target: target, dt: 1 / 30)
        XCTAssertEqual(long.0, clamped.0)
        XCTAssertEqual(long.1, clamped.1)
    }

    func testGrowInCurveOvershootsBoundedAndSettlesWithinHalfSecond() {
        let curve = BallAppearanceCurve.growInDefault
        XCTAssertGreaterThanOrEqual(curve.duration, 0.40)
        XCTAssertLessThanOrEqual(curve.duration, 0.50)

        let start = curve.sample(at: 0)
        XCTAssertGreaterThanOrEqual(start.scale, 0.2)
        XCTAssertLessThanOrEqual(start.scale, 0.4)
        XCTAssertEqual(start.opacity, 0.0, accuracy: 0.001)
        XCTAssertFalse(start.isBurst)
        XCTAssertFalse(start.isSettled)

        var maxScale: CGFloat = 0
        for step in 0...100 {
            let t = curve.duration * Double(step) / 100.0
            let s = curve.sample(at: t)
            maxScale = max(maxScale, s.scale)
            XCTAssertFalse(s.isBurst)
        }
        XCTAssertGreaterThan(maxScale, 1.01)
        XCTAssertLessThanOrEqual(maxScale, 1.08)

        let end = curve.sample(at: curve.duration)
        XCTAssertTrue(end.isSettled)
        XCTAssertEqual(end.scale, 1.0, accuracy: 0.0001)
        XCTAssertEqual(end.opacity, 1.0, accuracy: 0.0001)
    }

    func testPopOutCurveSwellsThenShrinksToZeroWithBurst() {
        let curve = BallAppearanceCurve.popOutDefault
        XCTAssertGreaterThanOrEqual(curve.duration, 0.20)
        XCTAssertLessThanOrEqual(curve.duration, 0.30)

        let start = curve.sample(at: 0)
        XCTAssertEqual(start.scale, 1.0, accuracy: 0.001)
        XCTAssertEqual(start.opacity, 1.0, accuracy: 0.001)
        XCTAssertFalse(start.isBurst)

        let swellPeak = curve.sample(at: 0.079)
        XCTAssertGreaterThanOrEqual(swellPeak.scale, 1.12)
        XCTAssertLessThanOrEqual(swellPeak.scale, 1.15)
        XCTAssertEqual(swellPeak.opacity, 1.0, accuracy: 0.001)
        XCTAssertFalse(swellPeak.isBurst)

        let midShrink = curve.sample(at: 0.16)
        XCTAssertTrue(midShrink.isBurst)
        XCTAssertGreaterThan(midShrink.burstProgress, 0.0)
        XCTAssertLessThan(midShrink.burstProgress, 1.0)
        XCTAssertLessThan(midShrink.scale, 1.0)

        let end = curve.sample(at: curve.duration)
        XCTAssertTrue(end.isSettled)
        XCTAssertTrue(end.isBurst)
        XCTAssertEqual(end.scale, 0.0, accuracy: 0.0001)
        XCTAssertEqual(end.opacity, 0.0, accuracy: 0.0001)
        XCTAssertEqual(end.burstProgress, 1.0, accuracy: 0.0001)
    }

    func testReduceMotionAppearanceCurvesFadeWithoutScaleOrBurst() {
        let fadeIn = BallAppearanceCurve.reduceMotionFadeInDefault
        let fadeOut = BallAppearanceCurve.reduceMotionFadeOutDefault
        for step in 0...20 {
            let sIn = fadeIn.sample(at: fadeIn.duration * Double(step) / 20.0)
            XCTAssertEqual(sIn.scale, 1.0, accuracy: 0.0001)
            XCTAssertFalse(sIn.isBurst)

            let sOut = fadeOut.sample(at: fadeOut.duration * Double(step) / 20.0)
            XCTAssertEqual(sOut.scale, 1.0, accuracy: 0.0001)
            XCTAssertFalse(sOut.isBurst)
        }
        XCTAssertEqual(fadeIn.sample(at: 0).opacity, 0.0, accuracy: 0.001)
        XCTAssertEqual(fadeIn.sample(at: fadeIn.duration).opacity, 1.0, accuracy: 0.001)
        XCTAssertEqual(fadeOut.sample(at: 0).opacity, 1.0, accuracy: 0.001)
        XCTAssertEqual(fadeOut.sample(at: fadeOut.duration).opacity, 0.0, accuracy: 0.001)
    }
}

import XCTest
import SwiftUI
@testable import SqueezeBar

final class ActiveRowLiquidProgressTests: XCTestCase {
    func testShapeEmptyAtZeroAndFullAtOne() {
        let rect = CGRect(x: 0, y: 0, width: 420, height: 50)
        XCTAssertTrue(LiquidProgressShape(progress: 0).path(in: rect).isEmpty)
        XCTAssertTrue(LiquidProgressShape(progress: -0.2).path(in: rect).isEmpty)
        XCTAssertTrue(LiquidProgressMeniscusShape(progress: 0).path(in: rect).isEmpty)

        let fullPath = LiquidProgressShape(progress: 1.0).path(in: rect)
        XCTAssertFalse(fullPath.isEmpty)
        XCTAssertEqual(fullPath.boundingRect.minX, rect.minX, accuracy: 0.01)
        XCTAssertEqual(fullPath.boundingRect.maxX, rect.maxX, accuracy: 0.01)
        XCTAssertEqual(fullPath.boundingRect.minY, rect.minY, accuracy: 0.01)
        XCTAssertEqual(fullPath.boundingRect.maxY, rect.maxY, accuracy: 0.01)
        XCTAssertTrue(LiquidProgressMeniscusShape(progress: 1.0).path(in: rect).isEmpty)
    }

    func testShapeRemainsStrictlyInsideContainerAndAdvancesMonotonically() {
        let rect = CGRect(x: 0, y: 0, width: 420, height: 50)
        var previousMaxX: CGFloat = 0
        for step in 1...100 {
            let p = CGFloat(step) / 100
            let path = LiquidProgressShape(progress: p, cornerRadius: 10, maxBulge: 9).path(in: rect)
            let bounds = path.boundingRect
            XCTAssertGreaterThanOrEqual(bounds.minX, rect.minX - 0.01)
            XCTAssertLessThanOrEqual(bounds.maxX, rect.maxX + 0.01)
            XCTAssertGreaterThanOrEqual(bounds.minY, rect.minY - 0.01)
            XCTAssertLessThanOrEqual(bounds.maxY, rect.maxY + 0.01)
            XCTAssertEqual(bounds.maxX, rect.width * p, accuracy: 0.25)
            XCTAssertGreaterThanOrEqual(bounds.maxX, previousMaxX - 0.01)
            previousMaxX = bounds.maxX
        }
    }

    func testSustainedTenHzCadenceAndSettle() {
        var lead = LiquidProgressMotion.State()
        var body = LiquidProgressMotion.State()

        // 10 Hz ProgressGate cadence: 0.05 per 0.1 s tick for 1.2 s (up to 0.60)
        var maxLeadGap = 0.0
        var steadyStateLead = 0.0
        var steadyStateBody = 0.0
        for tick in 1...12 {
            let target = Double(tick) * 0.05
            // Sub-step at 60 Hz over the 0.1 s interval
            for frame in 0..<6 {
                let newTarget: Double? = (frame == 0) ? target : nil
                LiquidProgressMotion.step(&lead, spring: LiquidProgressMotion.leadSpring, to: newTarget, dt: 1.0 / 60.0)
                LiquidProgressMotion.step(&body, spring: LiquidProgressMotion.bodySpring, to: newTarget, dt: 1.0 / 60.0)
                XCTAssertLessThanOrEqual(lead.value, target + 1e-6, "No overshoot past current target")
                XCTAssertLessThanOrEqual(body.value, target + 1e-6, "No overshoot past current target")
                XCTAssertGreaterThanOrEqual(lead.value, body.value - 1e-6, "Lead tide never lags behind body on monotonic climb")
                maxLeadGap = max(maxLeadGap, lead.value - body.value)
            }
            if tick == 12 {
                steadyStateLead = lead.value
                steadyStateBody = body.value
            }
        }
        // At 10 Hz sustained updates, both should track closely (~90%+ of each step) and show gentle separation.
        XCTAssertGreaterThan(steadyStateLead, 0.54)
        XCTAssertGreaterThan(steadyStateBody, 0.52)
        XCTAssertGreaterThan(maxLeadGap, 0.003)
        XCTAssertLessThan(maxLeadGap, 0.05)

        // Settle after final update stops
        var elapsed = 0.0
        while elapsed < 0.8 {
            LiquidProgressMotion.step(&lead, spring: LiquidProgressMotion.leadSpring, dt: 1.0 / 60.0)
            LiquidProgressMotion.step(&body, spring: LiquidProgressMotion.bodySpring, dt: 1.0 / 60.0)
            elapsed += 1.0 / 60.0
            if LiquidProgressMotion.isSettled(lead) && LiquidProgressMotion.isSettled(body) {
                break
            }
        }
        XCTAssertTrue(LiquidProgressMotion.isSettled(lead))
        XCTAssertTrue(LiquidProgressMotion.isSettled(body))
        XCTAssertLessThanOrEqual(elapsed, 0.40)
        XCTAssertEqual(lead.value, 0.60, accuracy: 0.001)
        XCTAssertEqual(body.value, 0.60, accuracy: 0.001)
    }

    func testSparseUpdatesRapidRetargetsAndRepeatedUpdates() {
        var lead = LiquidProgressMotion.State()
        var body = LiquidProgressMotion.State()

        // Sparse update: 0.0 -> 0.40, idle for 0.5 s
        LiquidProgressMotion.step(&lead, spring: LiquidProgressMotion.leadSpring, to: 0.40, dt: 0)
        LiquidProgressMotion.step(&body, spring: LiquidProgressMotion.bodySpring, to: 0.40, dt: 0)
        var peakDeformation = 0.0
        for _ in 0..<30 {
            LiquidProgressMotion.step(&lead, spring: LiquidProgressMotion.leadSpring, dt: 1.0 / 60.0)
            LiquidProgressMotion.step(&body, spring: LiquidProgressMotion.bodySpring, dt: 1.0 / 60.0)
            XCTAssertLessThanOrEqual(lead.value, 0.40 + 1e-6)
            peakDeformation = max(peakDeformation, lead.value - body.value)
        }
        XCTAssertGreaterThan(peakDeformation, 0.02, "Sparse jump creates gentle leading liquid tide")
        XCTAssertTrue(LiquidProgressMotion.isSettled(lead))
        XCTAssertTrue(LiquidProgressMotion.isSettled(body))

        // Repeated identical update should keep settled state unchanged
        LiquidProgressMotion.step(&lead, spring: LiquidProgressMotion.leadSpring, to: 0.40, dt: 1.0 / 60.0)
        LiquidProgressMotion.step(&body, spring: LiquidProgressMotion.bodySpring, to: 0.40, dt: 1.0 / 60.0)
        XCTAssertEqual(lead.value, 0.40, accuracy: 0.0005)
        XCTAssertEqual(body.value, 0.40, accuracy: 0.0005)

        // Rapid retargets every 25 ms up to 1.0
        for target in [0.55, 0.70, 0.88, 1.0] {
            LiquidProgressMotion.step(&lead, spring: LiquidProgressMotion.leadSpring, to: target, dt: 0.025)
            LiquidProgressMotion.step(&body, spring: LiquidProgressMotion.bodySpring, to: target, dt: 0.025)
            XCTAssertLessThanOrEqual(lead.value, 1.0 + 1e-6)
            XCTAssertLessThanOrEqual(body.value, 1.0 + 1e-6)
        }

        // Settle cleanly at 1.0 within 0.4 s
        for _ in 0..<24 {
            LiquidProgressMotion.step(&lead, spring: LiquidProgressMotion.leadSpring, dt: 1.0 / 60.0)
            LiquidProgressMotion.step(&body, spring: LiquidProgressMotion.bodySpring, dt: 1.0 / 60.0)
        }
        XCTAssertTrue(LiquidProgressMotion.isSettled(lead))
        XCTAssertTrue(LiquidProgressMotion.isSettled(body))
        XCTAssertEqual(lead.value, 1.0, accuracy: 0.001)
        XCTAssertEqual(body.value, 1.0, accuracy: 0.001)
    }

    func testReduceMotionDisablesAnimation() {
        XCTAssertNil(LiquidProgressMotion.animation(LiquidProgressMotion.leadSpring, reduceMotion: true))
        XCTAssertNil(LiquidProgressMotion.animation(LiquidProgressMotion.bodySpring, reduceMotion: true))
        XCTAssertNotNil(LiquidProgressMotion.animation(LiquidProgressMotion.leadSpring, reduceMotion: false))
        XCTAssertNotNil(LiquidProgressMotion.animation(LiquidProgressMotion.bodySpring, reduceMotion: false))
    }
}

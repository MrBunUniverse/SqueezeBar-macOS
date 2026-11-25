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

    func testSpringsAreCriticallyDampedAndSettlePromptly() {
        let springs = [LiquidProgressMotion.leadSpring, LiquidProgressMotion.bodySpring]
        for spring in springs {
            XCTAssertEqual(spring.bounce, 0, accuracy: 1e-9)
            XCTAssertLessThanOrEqual(spring.settlingDuration(target: 1.0, initialVelocity: 0.0, epsilon: 0.005), 0.35)
            for step in 0...50 {
                let t = Double(step) * 0.01
                let value = spring.value(target: 1.0, initialVelocity: 0.0, time: t)
                XCTAssertGreaterThanOrEqual(value, -1e-6)
                XCTAssertLessThanOrEqual(value, 1.0 + 1e-6)
            }
            XCTAssertEqual(spring.value(target: 1.0, initialVelocity: 0.0, time: 0.30), 1.0, accuracy: 0.01)
        }

        XCTAssertGreaterThan(
            LiquidProgressMotion.leadSpring.value(target: 1.0, initialVelocity: 0.0, time: 0.05),
            LiquidProgressMotion.bodySpring.value(target: 1.0, initialVelocity: 0.0, time: 0.05)
        )
    }

    func testReduceMotionDisablesAnimation() {
        XCTAssertNil(LiquidProgressMotion.animation(LiquidProgressMotion.leadSpring, reduceMotion: true))
        XCTAssertNil(LiquidProgressMotion.animation(LiquidProgressMotion.bodySpring, reduceMotion: true))
        XCTAssertNotNil(LiquidProgressMotion.animation(LiquidProgressMotion.leadSpring, reduceMotion: false))
        XCTAssertNotNil(LiquidProgressMotion.animation(LiquidProgressMotion.bodySpring, reduceMotion: false))
    }
}

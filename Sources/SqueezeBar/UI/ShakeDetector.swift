import Foundation
import CoreGraphics

/// Detects a horizontal back-and-forth shake gesture while dragging files.
public struct ShakeDetector: Sendable {
    // Tuning knobs for shake-to-summon gesture detection.
    public static let minLegDistance: CGFloat = 30
    public static let requiredReversals: Int = 3
    public static let reversalWindow: TimeInterval = 0.6

    private var minX: CGFloat?
    private var maxX: CGFloat?
    private var extremeX: CGFloat = 0
    private var currentDirection: Int = 0
    private var reversalTimes: [TimeInterval] = []
    public private(set) var hasFired: Bool = false
    public private(set) var lastHorizontalDirection: CGFloat = 0

    public init() {}

    public mutating func reset() {
        minX = nil
        maxX = nil
        extremeX = 0
        currentDirection = 0
        reversalTimes.removeAll(keepingCapacity: true)
        hasFired = false
        lastHorizontalDirection = 0
    }

    @discardableResult
    public mutating func add(point: CGPoint, time: TimeInterval) -> Bool {
        guard !hasFired else { return false }

        let x = point.x
        guard let currentMinX = minX, let currentMaxX = maxX else {
            minX = x
            maxX = x
            extremeX = x
            return false
        }

        if currentDirection == 0 {
            if x < currentMinX {
                minX = x
                lastHorizontalDirection = -1
            }
            if x > currentMaxX {
                maxX = x
                lastHorizontalDirection = 1
            }

            if x - (minX ?? x) >= Self.minLegDistance {
                currentDirection = 1
                extremeX = x
                lastHorizontalDirection = 1
            } else if (maxX ?? x) - x >= Self.minLegDistance {
                currentDirection = -1
                extremeX = x
                lastHorizontalDirection = -1
            }
            return false
        }

        if currentDirection == 1 {
            if x > extremeX {
                extremeX = x
                lastHorizontalDirection = 1
                return false
            }
            if extremeX - x >= Self.minLegDistance {
                currentDirection = -1
                extremeX = x
                lastHorizontalDirection = -1
                return recordReversal(at: time)
            }
        } else {
            if x < extremeX {
                extremeX = x
                lastHorizontalDirection = -1
                return false
            }
            if x - extremeX >= Self.minLegDistance {
                currentDirection = 1
                extremeX = x
                lastHorizontalDirection = 1
                return recordReversal(at: time)
            }
        }

        return false
    }

    private mutating func recordReversal(at time: TimeInterval) -> Bool {
        reversalTimes.append(time)
        let cutoff = time - Self.reversalWindow
        reversalTimes.removeAll { $0 < cutoff }
        if reversalTimes.count >= Self.requiredReversals {
            hasFired = true
            return true
        }
        return false
    }
}

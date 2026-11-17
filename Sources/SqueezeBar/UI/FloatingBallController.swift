import Foundation
import AppKit
import SwiftUI
import Combine
import QuartzCore

// MARK: - Liquid Ball Physical Model
@MainActor
public final class LiquidBallModel: ObservableObject {
    public static let shared = LiquidBallModel()
    
    public enum DockEdge: String {
        case left
        case right
    }
    
    @Published public var scaleX: CGFloat = 1.0
    @Published public var scaleY: CGFloat = 1.0
    @Published public var rotationAngle: Double = 0.0
    @Published public var isMoving: Bool = false
    @Published public var isHovered: Bool = false
    @Published public var isDropTargeted: Bool = false
    @Published public var dockEdge: DockEdge = .right
    @Published public var isTucked: Bool = true
    @Published public var isSummoned: Bool = false
    /// Driven by `BallAppearanceCurve` in `FloatingBallController` so appear/dismiss animations are deterministic and cancellable.
    @Published public var appearanceScale: CGFloat = 1.0
    @Published public var appearanceOpacity: CGFloat = 1.0
    @Published public var burstProgress: CGFloat = 0.0
    @Published public var burstBaseScale: CGFloat = 1.14
    /// Set during the shrink/burst phase of pop-out so the expanding ring and droplets render around the shrinking orb.
    @Published public private(set) var isBurst: Bool = false
    /// True while a pop-out/fade-out dismiss animation is running before ordering out the panel.
    @Published public var isDismissing: Bool = false

    private var tuckTimerTask: Task<Void, Never>?

    public init() {}

    public func apply(_ sample: BallAppearanceCurve.Sample, burstBaseScale: CGFloat = 1.14) {
        if appearanceScale != sample.scale { appearanceScale = sample.scale }
        if appearanceOpacity != sample.opacity { appearanceOpacity = sample.opacity }
        if burstProgress != sample.burstProgress { burstProgress = sample.burstProgress }
        if self.burstBaseScale != burstBaseScale { self.burstBaseScale = burstBaseScale }
        if isBurst != sample.isBurst { isBurst = sample.isBurst }
    }

    public func resetAppearance() {
        appearanceScale = 1.0
        appearanceOpacity = 1.0
        burstProgress = 0.0
        burstBaseScale = 1.14
        isBurst = false
        isDismissing = false
    }
    
    public func applyMotionVelocity(dx: CGFloat, dy: CGFloat) {
        // Only publish on real changes: every @Published set re-renders the ball, even when the value is the same.
        if !isMoving { isMoving = true }
        if isTucked { isTucked = false }
        cancelTuckTimer()

        let speed = sqrt(dx * dx + dy * dy)
        let intensity = min(1.0, speed / 20.0)
        let absDx = abs(dx)
        let absDy = abs(dy)
        let stretchFactor: CGFloat = 0.42

        var targetScaleX: CGFloat = 1.0
        var targetScaleY: CGFloat = 1.0
        var targetAngle: Double = 0.0
        
        if absDx >= absDy {
            // Horizontal drag: stretch wide, squash tall
            targetScaleX = 1.0 + (stretchFactor * intensity)
            targetScaleY = 1.0 - (stretchFactor * 0.6 * intensity)
            targetAngle = Double(dx > 0 ? 6.0 : -6.0) * intensity
        } else {
            // Vertical drag: stretch tall, squash wide
            targetScaleX = 1.0 - (stretchFactor * 0.6 * intensity)
            targetScaleY = 1.0 + (stretchFactor * intensity)
            targetAngle = Double(dx * 0.18)
        }
        
        withAnimation(.interactiveSpring(response: 0.14, dampingFraction: 0.64)) {
            self.scaleX = targetScaleX
            self.scaleY = targetScaleY
            self.rotationAngle = targetAngle
        }
    }
    
    public func releaseMotion() {
        isMoving = false
        withAnimation(.spring(response: 0.42, dampingFraction: 0.42, blendDuration: 0.08)) {
            self.scaleX = 1.0
            self.scaleY = 1.0
            self.rotationAngle = 0.0
        }
    }
    
    public func revealFromTuck() {
        cancelTuckTimer()
        withAnimation(.spring(response: 0.40, dampingFraction: 0.44, blendDuration: 0.08)) {
            self.isTucked = false
        }
    }
    
    public func scheduleAutoTuck(afterSeconds: Double = 1.8) {
        cancelTuckTimer()
        tuckTimerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(afterSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if !self.isMoving && !AppState.shared.isProcessing && !self.isHovered && !self.isSummoned {
                withAnimation(.spring(response: 0.44, dampingFraction: 0.56)) {
                    self.isTucked = true
                }
            }
        }
    }
    
    public func cancelTuckTimer() {
        tuckTimerTask?.cancel()
        tuckTimerTask = nil
    }
}

// MARK: - Panel Origin & Opacity Timing Curves
public enum BallGlideCurve: Sendable {
    case snapEaseOut(duration: TimeInterval)
    case softSpring(response: TimeInterval, dampingRatio: Double, settleDuration: TimeInterval)
    case reduceMotionCrossFade(duration: TimeInterval)

    public static let snapDefault = BallGlideCurve.snapEaseOut(duration: 0.24)
    /// Peaks at ~0.40 s and settles completely by 0.70 s (< 0.8 s).
    public static let summonSpring = BallGlideCurve.softSpring(response: 0.48, dampingRatio: 0.80, settleDuration: 0.70)
    public static let reduceMotionDefault = BallGlideCurve.reduceMotionCrossFade(duration: 0.28)

    public var duration: TimeInterval {
        switch self {
        case .snapEaseOut(let duration): return duration
        case .softSpring(_, _, let settleDuration): return settleDuration
        case .reduceMotionCrossFade(let duration): return duration
        }
    }

    public struct Sample: Sendable {
        public let positionProgress: CGFloat
        public let alpha: CGFloat
        public let isSettled: Bool
    }

    public func sample(at elapsed: TimeInterval) -> Sample {
        let clampedElapsed = max(0, elapsed)
        switch self {
        case .snapEaseOut(let duration):
            let p = duration > 0 ? min(1.0, clampedElapsed / duration) : 1.0
            let t = 1.0 - pow(1.0 - p, 3.0)
            return Sample(positionProgress: CGFloat(t), alpha: 1.0, isSettled: p >= 1.0)

        case .softSpring(let response, let dampingRatio, let settleDuration):
            if clampedElapsed >= settleDuration {
                return Sample(positionProgress: 1.0, alpha: 1.0, isSettled: true)
            }
            let omegaN = (2.0 * .pi) / max(0.01, response)
            let zeta = min(0.999, max(0.05, dampingRatio))
            let root = sqrt(1.0 - zeta * zeta)
            let omegaD = omegaN * root
            let decay = exp(-zeta * omegaN * clampedElapsed)
            let raw = 1.0 - decay * (cos(omegaD * clampedElapsed) + (zeta / root) * sin(omegaD * clampedElapsed))
            let tailWindow = min(0.05, settleDuration * 0.1)
            let tailStart = settleDuration - tailWindow
            let progress: Double
            if clampedElapsed > tailStart, tailWindow > 0 {
                let blend = (clampedElapsed - tailStart) / tailWindow
                progress = raw + (1.0 - raw) * blend
            } else {
                progress = raw
            }
            return Sample(positionProgress: CGFloat(progress), alpha: 1.0, isSettled: false)

        case .reduceMotionCrossFade(let duration):
            let p = duration > 0 ? min(1.0, clampedElapsed / duration) : 1.0
            if p >= 1.0 {
                return Sample(positionProgress: 1.0, alpha: 1.0, isSettled: true)
            } else if p < 0.5 {
                return Sample(positionProgress: 0.0, alpha: CGFloat(1.0 - p * 2.0), isSettled: false)
            } else {
                return Sample(positionProgress: 1.0, alpha: CGFloat((p - 0.5) * 2.0), isSettled: false)
            }
        }
    }
}

// MARK: - Grow-In & Pop-Out Appearance Curves
public enum BallAppearanceCurve: Sendable {
    case growIn(
        startScale: CGFloat = 0.28,
        response: TimeInterval = 0.28,
        dampingRatio: Double = 0.60,
        settleDuration: TimeInterval = 0.46,
        fadeDuration: TimeInterval = 0.18
    )
    case popOut(
        fromScale: CGFloat = 1.0,
        fromOpacity: CGFloat = 1.0,
        swellScale: CGFloat = 1.14,
        swellDuration: TimeInterval = 0.08,
        shrinkDuration: TimeInterval = 0.18
    )
    case reduceMotionFadeIn(duration: TimeInterval = 0.18)
    case reduceMotionFadeOut(fromOpacity: CGFloat = 1.0, duration: TimeInterval = 0.18)

    public static let growInDefault = BallAppearanceCurve.growIn()
    public static let popOutDefault = BallAppearanceCurve.popOut()
    public static let reduceMotionFadeInDefault = BallAppearanceCurve.reduceMotionFadeIn()
    public static let reduceMotionFadeOutDefault = BallAppearanceCurve.reduceMotionFadeOut()

    public var duration: TimeInterval {
        switch self {
        case .growIn(_, _, _, let settleDuration, _):
            return settleDuration
        case .popOut(_, _, _, let swellDuration, let shrinkDuration):
            return swellDuration + shrinkDuration
        case .reduceMotionFadeIn(let duration):
            return duration
        case .reduceMotionFadeOut(_, let duration):
            return duration
        }
    }

    public var burstBaseScale: CGFloat {
        switch self {
        case .popOut(_, _, let swellScale, _, _):
            return swellScale
        case .growIn, .reduceMotionFadeIn, .reduceMotionFadeOut:
            return 1.14
        }
    }

    public struct Sample: Sendable {
        public let scale: CGFloat
        public let opacity: CGFloat
        public let burstProgress: CGFloat
        public let isBurst: Bool
        public let isSettled: Bool
    }

    public func sample(at elapsed: TimeInterval) -> Sample {
        let t = max(0, elapsed)
        switch self {
        case .growIn(let startScale, let response, let dampingRatio, let settleDuration, let fadeDuration):
            let fadeP = fadeDuration > 0 ? min(1.0, t / fadeDuration) : 1.0
            let opacity = CGFloat(1.0 - pow(1.0 - fadeP, 2.0))
            if t >= settleDuration {
                return Sample(scale: 1.0, opacity: 1.0, burstProgress: 0.0, isBurst: false, isSettled: true)
            }
            let omegaN = (2.0 * .pi) / max(0.01, response)
            let zeta = min(0.999, max(0.05, dampingRatio))
            let root = sqrt(1.0 - zeta * zeta)
            let omegaD = omegaN * root
            let decay = exp(-zeta * omegaN * t)
            let raw = 1.0 - decay * (cos(omegaD * t) + (zeta / root) * sin(omegaD * t))
            let tailWindow = min(0.05, settleDuration * 0.1)
            let tailStart = settleDuration - tailWindow
            let progress: Double
            if t > tailStart, tailWindow > 0 {
                let blend = (t - tailStart) / tailWindow
                progress = raw + (1.0 - raw) * blend
            } else {
                progress = raw
            }
            let scale = startScale + (1.0 - startScale) * CGFloat(progress)
            return Sample(scale: scale, opacity: opacity, burstProgress: 0.0, isBurst: false, isSettled: false)

        case .popOut(let fromScale, let fromOpacity, let swellScale, let swellDuration, let shrinkDuration):
            let total = swellDuration + shrinkDuration
            if t >= total {
                return Sample(scale: 0.0, opacity: 0.0, burstProgress: 1.0, isBurst: true, isSettled: true)
            }
            if t < swellDuration {
                let p = swellDuration > 0 ? t / swellDuration : 1.0
                let eased = 1.0 - pow(1.0 - p, 2.0)
                let scale = fromScale + (swellScale - fromScale) * CGFloat(eased)
                let opacity = fromOpacity + (1.0 - fromOpacity) * CGFloat(eased)
                return Sample(scale: scale, opacity: opacity, burstProgress: 0.0, isBurst: false, isSettled: false)
            } else {
                let p = shrinkDuration > 0 ? min(1.0, (t - swellDuration) / shrinkDuration) : 1.0
                let scaleEase = 1.0 - pow(1.0 - p, 1.8)
                let scale = swellScale * CGFloat(max(0.0, 1.0 - scaleEase))
                let opacity = CGFloat(max(0.0, 1.0 - pow(p, 1.35)))
                return Sample(scale: scale, opacity: opacity, burstProgress: CGFloat(p), isBurst: true, isSettled: false)
            }

        case .reduceMotionFadeIn(let duration):
            let p = duration > 0 ? min(1.0, t / duration) : 1.0
            let opacity = CGFloat(1.0 - pow(1.0 - p, 2.0))
            return Sample(scale: 1.0, opacity: p >= 1.0 ? 1.0 : opacity, burstProgress: 0.0, isBurst: false, isSettled: p >= 1.0)

        case .reduceMotionFadeOut(let fromOpacity, let duration):
            let p = duration > 0 ? min(1.0, t / duration) : 1.0
            let opacity = fromOpacity * CGFloat(pow(1.0 - p, 2.0))
            return Sample(scale: 1.0, opacity: p >= 1.0 ? 0.0 : opacity, burstProgress: 0.0, isBurst: false, isSettled: p >= 1.0)
        }
    }
}

// MARK: - Floating Ball Hosting View with Proximity Snapping & Drag Physics
public final class FloatingBallHostingView: NSHostingView<FloatingBallView> {
    private var initialMouseLocation: CGPoint = .zero
    private var initialWindowOrigin: CGPoint = .zero
    private var lastMouseLocation: CGPoint = .zero
    private var isDraggingWindow = false

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let model = LiquidBallModel.shared
        guard !model.isDismissing, model.appearanceOpacity >= 0.05, model.appearanceScale >= 0.05 else {
            return nil
        }
        let state = AppState.shared
        let isTucked = model.isTucked && !model.isHovered && !state.isProcessing && !model.isMoving && !model.isSummoned
        let hoverScale: CGFloat = 1.15
        let popoutOffset: CGFloat = 22

        let offset = (model.isMoving || model.isSummoned) ? 0 : (isTucked ? FloatingBallController.tuckedOffset : -popoutOffset) * (model.dockEdge == .right ? 1 : -1)
        let scaleX = (isTucked ? FloatingBallController.tuckedScaleX : (model.isHovered ? hoverScale : 1)) * model.scaleX
        let scaleY = (isTucked ? 1.06 : (model.isHovered ? hoverScale : 1)) * model.scaleY
        let effectiveScaleX = scaleX * model.appearanceScale
        let effectiveScaleY = scaleY * model.appearanceScale
        let localPoint = convert(point, from: superview)
        let center = CGPoint(x: FloatingBallController.panelSize / 2 + offset * scaleX, y: FloatingBallController.panelSize / 2)
        let unscaledPoint = CGPoint(
            x: center.x + (localPoint.x - center.x) / effectiveScaleX,
            y: center.y + (localPoint.y - center.y) / effectiveScaleY
        )
        let ballRect = CGRect(
            x: center.x - FloatingBallController.orbSize / 2,
            y: center.y - FloatingBallController.orbSize / 2,
            width: FloatingBallController.orbSize,
            height: FloatingBallController.orbSize
        )
        let shape = DockedBallShape(tuckProgress: isTucked ? 1 : 0, isRightEdge: model.dockEdge == .right)
        guard shape.path(in: ballRect).contains(unscaledPoint) else {
            return nil
        }
        return super.hitTest(point)
    }
    
    public override func mouseDown(with event: NSEvent) {
        initialMouseLocation = NSEvent.mouseLocation
        lastMouseLocation = initialMouseLocation
        initialWindowOrigin = window?.frame.origin ?? .zero
        isDraggingWindow = false
        Task { @MainActor in
            LiquidBallModel.shared.revealFromTuck()
        }
    }
    
    public override func mouseDragged(with event: NSEvent) {
        let currentMouse = NSEvent.mouseLocation
        let deltaX = currentMouse.x - initialMouseLocation.x
        let deltaY = currentMouse.y - initialMouseLocation.y
        let distance = sqrt(deltaX * deltaX + deltaY * deltaY)
        
        if distance > 2.0 {
            if !isDraggingWindow {
                isDraggingWindow = true
                MainActor.assumeIsolated {
                    FloatingBallController.shared.userDidStartManualDrag()
                }
            }
            
            // Move window directly on GPU
            let newOrigin = CGPoint(
                x: initialWindowOrigin.x + deltaX,
                y: initialWindowOrigin.y + deltaY
            )
            window?.setFrameOrigin(newOrigin)
            
            // Update dynamic liquid squash and stretch physics
            let stepDx = currentMouse.x - lastMouseLocation.x
            let stepDy = currentMouse.y - lastMouseLocation.y
            Task { @MainActor in
                LiquidBallModel.shared.applyMotionVelocity(dx: stepDx, dy: stepDy)
            }
            lastMouseLocation = currentMouse
        }
    }
    
    public override func mouseUp(with event: NSEvent) {
        if isDraggingWindow {
            Task { @MainActor in
                LiquidBallModel.shared.releaseMotion()
                FloatingBallController.shared.snapToNearestScreenEdge()
            }
            isDraggingWindow = false
        } else {
            // Click without drag toggles the main popover/window
            Task { @MainActor in
                FloatingBallController.shared.toggleMainPopover()
                LiquidBallModel.shared.scheduleAutoTuck(afterSeconds: 2.5)
            }
        }
    }
}

// MARK: - Floating Ball Window Controller
@MainActor
public final class FloatingBallController: NSObject, NSWindowDelegate {
    public static let shared = FloatingBallController()
    static let panelSize: CGFloat = 160
    static let orbSize: CGFloat = 58
    static let tuckedScaleX: CGFloat = 0.68
    static let tuckedOffset: CGFloat = (orbSize / 2) * (1 / tuckedScaleX - 1)

    static let summonCursorOffset: CGFloat = 54
    static let summonSkipDistanceThreshold: CGFloat = 150
    static let summonScreenMargin: CGFloat = 12
    static let postDropReturnDelay: TimeInterval = 1.0
    
    // Magnet tuning knobs: points, seconds, and dimensionless damping.
    static let magnetRadius: CGFloat = 160
    static let maxDrift: CGFloat = 28
    static let magnetStiffness: CGFloat = 170
    static let magnetDampingRatio: CGFloat = 0.78
    private var magnetAnchor: CGPoint?
    private var magnetCenter: CGPoint?
    private var magnetPosition: CGPoint = .zero
    private var magnetVelocity: CGVector = .zero
    private var magnetTarget: CGPoint = .zero
    private var magnetDisplayLink: CADisplayLink?
    private var magnetTimestamp: CFTimeInterval?
    private var magnetHoverCancellable: AnyCancellable?
    private var globalMoveMonitor: Any?
    private var localMoveMonitor: Any?

    private var ballPanel: NSPanel?
    private var ballSize: CGFloat { Self.panelSize }
    private var snapTimer: Timer?
    private var appearanceTimer: Timer?
    private var appearanceGeneration: UInt64 = 0
    private var quitPopContinuation: CheckedContinuation<Void, Never>?

    // Shake-to-summon state
    private var globalDragMonitor: Any?
    private var localKeyMonitor: Any?
    private var lastDragChangeCount: Int = 0
    private var isFileDragActive: Bool = false
    private var shakeDetector = ShakeDetector()

    private var dockAnchor: (origin: CGPoint, edge: LiquidBallModel.DockEdge)?
    private var isSummoned: Bool = false
    private var isTemporarySummon: Bool = false
    private var summonedInPlace: Bool = false
    private var dropInitiated: Bool = false
    private var sawProcessingSinceSummon: Bool = false

    private var processingCancellable: AnyCancellable?
    private var returnDelayTask: Task<Void, Never>?
    private var dragEndGraceTask: Task<Void, Never>?
    private var dropFallbackTask: Task<Void, Never>?
    
    private struct Keys {
        static let ballOriginX = "squeezebar.floatingBallOriginX"
        static let ballOriginY = "squeezebar.floatingBallOriginY"
        static let dockEdge = "squeezebar.dockEdge"
    }
    
    public override init() {
        super.init()
    }
    
    public func saveCurrentPosition() {
        guard let panel = ballPanel,
              !isSummoned,
              !isTemporarySummon,
              !summonedInPlace,
              dockAnchor == nil else { return }
        let origin = panel.frame.origin
        UserDefaults.standard.set(Double(origin.x), forKey: Keys.ballOriginX)
        UserDefaults.standard.set(Double(origin.y), forKey: Keys.ballOriginY)
        UserDefaults.standard.set(LiquidBallModel.shared.dockEdge.rawValue, forKey: Keys.dockEdge)
    }

    // MARK: - Drag Monitor Lifecycle

    public func updateDragMonitor() {
        if AppState.shared.shakeToSummonEnabled {
            startDragMonitorIfNeeded()
        } else {
            stopDragMonitor()
            if isSummoned || summonedInPlace {
                returnFromSummon()
            }
        }
    }

    public func stopDragMonitor() {
        if let monitor = globalDragMonitor {
            NSEvent.removeMonitor(monitor)
            globalDragMonitor = nil
        }
        isFileDragActive = false
        shakeDetector.reset()
    }

    private func startDragMonitorIfNeeded() {
        guard globalDragMonitor == nil else { return }
        lastDragChangeCount = NSPasteboard(name: .drag).changeCount
        isFileDragActive = false
        shakeDetector.reset()

        globalDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleGlobalDragEvent(event)
            }
        }
    }

    private func handleGlobalDragEvent(_ event: NSEvent) {
        guard AppState.shared.shakeToSummonEnabled else { return }

        switch event.type {
        case .leftMouseDragged:
            updateMagnet()
            if !isFileDragActive {
                let dragPasteboard = NSPasteboard(name: .drag)
                let changeCount = dragPasteboard.changeCount
                if changeCount != lastDragChangeCount {
                    lastDragChangeCount = changeCount
                    if Self.pasteboardContainsFileURLs(dragPasteboard) {
                        isFileDragActive = true
                        shakeDetector.reset()
                        _ = shakeDetector.add(point: NSEvent.mouseLocation, time: event.timestamp)
                    }
                }
                return
            }

            if shakeDetector.add(point: NSEvent.mouseLocation, time: event.timestamp) {
                summonNearCursor(
                    cursor: NSEvent.mouseLocation,
                    dragDirection: shakeDetector.lastHorizontalDirection
                )
            }

        case .leftMouseUp:
            let wasActive = isFileDragActive
            isFileDragActive = false
            shakeDetector.reset()
            if wasActive || isSummoned || summonedInPlace {
                handleGlobalDragMouseUp()
            }

        default:
            break
        }
    }

    static func pasteboardContainsFileURLs(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return true
        }
        let types = pasteboard.types ?? []
        return types.contains(.fileURL)
            || types.contains(NSPasteboard.PasteboardType("NSFilenamesPboardType"))
            || types.contains(NSPasteboard.PasteboardType("public.file-url"))
            || types.contains(NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"))
    }

    // MARK: - Summon & Return

    /// Computes the panel origin so the visible orb sits ~54 pt beside the cursor on the side away
    /// from the drag direction, clamped to `visibleFrame` and never overlapping the cursor.
    public static func summonTargetOrigin(
        cursor: CGPoint,
        dragDirection: CGFloat,
        visibleFrame: NSRect
    ) -> CGPoint {
        let orbHalf = orbSize / 2
        let minCenterX = visibleFrame.minX + orbHalf + summonScreenMargin
        let maxCenterX = visibleFrame.maxX - orbHalf - summonScreenMargin
        let minCenterY = visibleFrame.minY + orbHalf + summonScreenMargin
        let maxCenterY = visibleFrame.maxY - orbHalf - summonScreenMargin

        let preferredSide: CGFloat
        if dragDirection > 0 {
            preferredSide = -1
        } else if dragDirection < 0 {
            preferredSide = 1
        } else {
            let roomLeft = cursor.x - visibleFrame.minX
            let roomRight = visibleFrame.maxX - cursor.x
            preferredSide = roomLeft >= roomRight ? -1 : 1
        }

        let candidate1 = min(maxCenterX, max(minCenterX, cursor.x + preferredSide * summonCursorOffset))
        var centerX = candidate1
        // If clamping pushed the ball close enough to overlap the cursor, flip to the opposite side.
        if abs(candidate1 - cursor.x) < orbHalf + 12 {
            let candidate2 = min(maxCenterX, max(minCenterX, cursor.x - preferredSide * summonCursorOffset))
            if abs(candidate2 - cursor.x) > abs(candidate1 - cursor.x) {
                centerX = candidate2
            }
        }

        let centerY = min(maxCenterY, max(minCenterY, cursor.y))
        return CGPoint(x: centerX - panelSize / 2, y: centerY - panelSize / 2)
    }

    public static func shouldSummonMove(currentOrbCenter: CGPoint, cursor: CGPoint) -> Bool {
        hypot(currentOrbCenter.x - cursor.x, currentOrbCenter.y - cursor.y) > summonSkipDistanceThreshold
    }

    private func currentVisibleOrbCenter() -> CGPoint {
        guard let panel = ballPanel else { return .zero }
        let model = LiquidBallModel.shared
        let offset: CGFloat
        if model.isSummoned || model.isMoving {
            offset = 0
        } else if model.isTucked {
            offset = (model.dockEdge == .right ? Self.tuckedOffset : -Self.tuckedOffset) * Self.tuckedScaleX
        } else {
            let popoutOffset: CGFloat = 22
            offset = model.dockEdge == .right ? -popoutOffset : popoutOffset
        }
        return CGPoint(x: panel.frame.midX + offset, y: panel.frame.midY)
    }

    private func summonNearCursor(cursor: CGPoint, dragDirection: CGFloat) {
        guard AppState.shared.shakeToSummonEnabled, !isSummoned, !summonedInPlace else { return }

        let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let targetOrigin = Self.summonTargetOrigin(
            cursor: cursor,
            dragDirection: dragDirection,
            visibleFrame: visibleFrame
        )

        let wasVisible = (ballPanel?.isVisible == true && !LiquidBallModel.shared.isDismissing)
        cancelAppearanceAnimation()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if AppState.shared.floatingBallEnabled {
            if ballPanel == nil {
                createPanel()
            }
            let appearCurve: BallAppearanceCurve = reduceMotion ? .reduceMotionFadeInDefault : .growInDefault
            if !wasVisible {
                LiquidBallModel.shared.apply(appearCurve.sample(at: 0), burstBaseScale: appearCurve.burstBaseScale)
            }
            ballPanel?.alphaValue = 1.0
            ballPanel?.level = .floating
            ballPanel?.orderFrontRegardless()
            if !wasVisible {
                animateAppearance(curve: appearCurve)
            }
            playHapticPair(.alignment, .levelChange)

            if !isSummoned && !Self.shouldSummonMove(currentOrbCenter: currentVisibleOrbCenter(), cursor: cursor) {
                cancelSummonTasks()
                summonedInPlace = true
                dropInitiated = false
                sawProcessingSinceSummon = AppState.shared.isProcessing
                LiquidBallModel.shared.revealFromTuck()
                installSummonObservers()
                beginMagnet()
                return
            }

            cancelSummonTasks()
            if dockAnchor == nil, let panel = ballPanel {
                dockAnchor = (origin: panel.frame.origin, edge: LiquidBallModel.shared.dockEdge)
            }
            isTemporarySummon = false
            isSummoned = true
            summonedInPlace = false
            dropInitiated = false
            sawProcessingSinceSummon = false
            LiquidBallModel.shared.isSummoned = true
            LiquidBallModel.shared.revealFromTuck()
            installSummonObservers()

            if !wasVisible && reduceMotion {
                snapTimer?.invalidate()
                snapTimer = nil
                ballPanel?.setFrameOrigin(targetOrigin)
                beginMagnet()
            } else {
                let curve: BallGlideCurve = reduceMotion
                    ? .reduceMotionDefault
                    : .summonSpring
                animatePanel(to: targetOrigin, curve: curve, onComplete: { [weak self] in self?.beginMagnet() })
            }
        } else {
            cancelSummonTasks()
            snapTimer?.invalidate()
            snapTimer = nil
            if ballPanel == nil {
                createPanel()
            }
            dockAnchor = nil
            isTemporarySummon = true
            isSummoned = true
            summonedInPlace = false
            dropInitiated = false
            sawProcessingSinceSummon = false
            LiquidBallModel.shared.isSummoned = true
            LiquidBallModel.shared.isTucked = false
            LiquidBallModel.shared.cancelTuckTimer()

            let appearCurve: BallAppearanceCurve = reduceMotion ? .reduceMotionFadeInDefault : .growInDefault
            LiquidBallModel.shared.apply(appearCurve.sample(at: 0), burstBaseScale: appearCurve.burstBaseScale)

            ballPanel?.setFrameOrigin(targetOrigin)
            ballPanel?.alphaValue = 1.0
            ballPanel?.level = .floating
            ballPanel?.orderFrontRegardless()
            installSummonObservers()
            animateAppearance(curve: appearCurve, onComplete: { [weak self] in
                self?.beginMagnet()
            })
            playHapticPair(.alignment, .levelChange)
        }
    }

    static func magnetTarget(anchor: CGPoint, cursor: CGPoint) -> CGPoint {
        let center = CGPoint(x: anchor.x + panelSize / 2, y: anchor.y + panelSize / 2)
        let dx = cursor.x - center.x, dy = cursor.y - center.y
        let distance = hypot(dx, dy)
        guard distance > 0, distance < magnetRadius else { return anchor }
        let proximity = 1 - distance / magnetRadius
        let pull = maxDrift * proximity * proximity * (3 - 2 * proximity)
        return CGPoint(x: anchor.x + dx / distance * pull, y: anchor.y + dy / distance * pull)
    }

    private func beginMagnet() {
        guard isSummoned || summonedInPlace, let panel = ballPanel else { return }
        magnetAnchor = panel.frame.origin
        magnetCenter = currentVisibleOrbCenter()
        magnetPosition = panel.frame.origin
        magnetVelocity = .zero
        magnetTarget = magnetPosition
        magnetHoverCancellable = LiquidBallModel.shared.$isDropTargeted
            .removeDuplicates()
            .sink { [weak self] targeted in
                if targeted { self?.stopMagnet() }
            }
        updateMagnet()
    }

    private func updateMagnet() {
        guard isSummoned || summonedInPlace, let anchor = magnetAnchor,
              let center = magnetCenter, let panel = ballPanel else { return }
        if LiquidBallModel.shared.isDropTargeted {
            stopMagnet()
            return
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            stopMagnet()
            magnetPosition = anchor
            magnetTarget = anchor
            panel.setFrameOrigin(anchor)
            return
        }
        let cursor = NSEvent.mouseLocation
        let adjustedCursor = CGPoint(x: cursor.x + anchor.x + Self.panelSize / 2 - center.x,
                                     y: cursor.y + anchor.y + Self.panelSize / 2 - center.y)
        magnetTarget = Self.magnetTarget(anchor: anchor, cursor: adjustedCursor)
        guard magnetDisplayLink == nil,
              magnetPosition != magnetTarget || magnetVelocity != .zero else { return }
        magnetTimestamp = CACurrentMediaTime()
        magnetDisplayLink = panel.contentView?.displayLink(target: self, selector: #selector(stepMagnet(_:)))
        magnetDisplayLink?.add(to: .main, forMode: .common)
    }

    static func springStep(position: CGPoint, velocity: CGVector, target: CGPoint,
                           dt: TimeInterval) -> (CGPoint, CGVector) {
        let dt = CGFloat(max(0, min(dt, 1.0 / 30)))
        let damping = 2 * magnetDampingRatio * sqrt(magnetStiffness)
        let velocity = CGVector(
            dx: velocity.dx + (magnetStiffness * (target.x - position.x) - damping * velocity.dx) * dt,
            dy: velocity.dy + (magnetStiffness * (target.y - position.y) - damping * velocity.dy) * dt)
        let position = CGPoint(x: position.x + velocity.dx * dt, y: position.y + velocity.dy * dt)
        if hypot(position.x - target.x, position.y - target.y) < 0.25,
           hypot(velocity.dx, velocity.dy) < 2 {
            return (target, .zero)
        }
        return (position, velocity)
    }

    private func stopMagnet() {
        magnetDisplayLink?.invalidate()
        magnetDisplayLink = nil
        magnetTimestamp = nil
        magnetVelocity = .zero
        LiquidBallModel.shared.releaseMotion()
    }

    @objc private func stepMagnet(_ link: CADisplayLink) {
        guard let panel = ballPanel, let anchor = magnetAnchor else {
            stopMagnet()
            return
        }
        guard !LiquidBallModel.shared.isDropTargeted else {
            stopMagnet()
            return
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            updateMagnet()
            return
        }
        let now = CACurrentMediaTime()
        let dt = now - (magnetTimestamp ?? now)
        magnetTimestamp = now
        let previous = magnetPosition
        (magnetPosition, magnetVelocity) = Self.springStep(
            position: magnetPosition, velocity: magnetVelocity, target: magnetTarget, dt: dt)
        let dx = magnetPosition.x - anchor.x, dy = magnetPosition.y - anchor.y
        let distance = hypot(dx, dy)
        if distance > Self.maxDrift {
            let nx = dx / distance, ny = dy / distance
            magnetPosition = CGPoint(x: anchor.x + nx * Self.maxDrift, y: anchor.y + ny * Self.maxDrift)
            let outward = max(0, magnetVelocity.dx * nx + magnetVelocity.dy * ny)
            magnetVelocity.dx -= outward * nx
            magnetVelocity.dy -= outward * ny
        }
        panel.setFrameOrigin(magnetPosition)
        LiquidBallModel.shared.applyMotionVelocity(dx: magnetPosition.x - previous.x,
                                                  dy: magnetPosition.y - previous.y)
        if magnetPosition == magnetTarget && magnetVelocity == .zero {
            stopMagnet()
        }
    }

    public func markDropInitiated() {
        guard isSummoned || summonedInPlace else { return }
        dropInitiated = true
        dragEndGraceTask?.cancel()
        dragEndGraceTask = nil
        returnDelayTask?.cancel()
        returnDelayTask = nil

        if AppState.shared.isProcessing {
            sawProcessingSinceSummon = true
        }

        dropFallbackTask?.cancel()
        dropFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self = self else { return }
            if (self.isSummoned || self.summonedInPlace),
               !self.sawProcessingSinceSummon,
               !AppState.shared.isProcessing {
                self.returnFromSummon()
            }
        }
    }

    public func cancelPendingDropAndReturn() {
        guard isSummoned || summonedInPlace else { return }
        dropInitiated = false
        dropFallbackTask?.cancel()
        dropFallbackTask = nil
        if !AppState.shared.isProcessing {
            returnFromSummon()
        }
    }

    public func userDidStartManualDrag() {
        cancelSummonTasks()
        removeSummonObservers()
        snapTimer?.invalidate()
        snapTimer = nil
        isSummoned = false
        isTemporarySummon = false
        summonedInPlace = false
        dropInitiated = false
        sawProcessingSinceSummon = false
        dockAnchor = nil
        LiquidBallModel.shared.isSummoned = false
    }

    private func handleGlobalDragMouseUp() {
        guard isSummoned || summonedInPlace else { return }
        if dropInitiated || AppState.shared.isProcessing { return }

        dragEndGraceTask?.cancel()
        dragEndGraceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled, let self = self else { return }
            if (self.isSummoned || self.summonedInPlace),
               !self.dropInitiated,
               !AppState.shared.isProcessing,
               !LiquidBallModel.shared.isDropTargeted {
                self.returnFromSummon()
            }
        }
    }

    private func handleEscapeKeyPressed() {
        guard isSummoned || summonedInPlace else { return }
        returnFromSummon()
    }

    private func installSummonObservers() {
        if globalMoveMonitor == nil {
            globalMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMagnet() }
            }
            localMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
                MainActor.assumeIsolated { self?.updateMagnet() }
                return event
            }
        }
        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return event }
                MainActor.assumeIsolated {
                    self?.handleEscapeKeyPressed()
                }
                return nil
            }
        }

        if processingCancellable == nil {
            processingCancellable = AppState.shared.jobs.$isProcessing
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isProcessing in
                    guard let self = self else { return }
                    guard self.isSummoned || self.summonedInPlace else { return }
                    if isProcessing {
                        self.sawProcessingSinceSummon = true
                        self.dropFallbackTask?.cancel()
                        self.dropFallbackTask = nil
                        self.returnDelayTask?.cancel()
                        self.returnDelayTask = nil
                    } else if self.sawProcessingSinceSummon {
                        self.schedulePostJobReturn()
                    }
                }
        }
    }

    private func removeSummonObservers() {
        for monitor in [globalMoveMonitor, localMoveMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        globalMoveMonitor = nil
        localMoveMonitor = nil
        stopMagnet()
        magnetHoverCancellable = nil
        magnetAnchor = nil
        magnetCenter = nil
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        processingCancellable?.cancel()
        processingCancellable = nil
    }

    private func cancelSummonTasks() {
        returnDelayTask?.cancel()
        returnDelayTask = nil
        dragEndGraceTask?.cancel()
        dragEndGraceTask = nil
        dropFallbackTask?.cancel()
        dropFallbackTask = nil
    }

    private func schedulePostJobReturn() {
        returnDelayTask?.cancel()
        returnDelayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.postDropReturnDelay * 1_000_000_000))
            guard !Task.isCancelled, let self = self else { return }
            if (self.isSummoned || self.summonedInPlace), !AppState.shared.isProcessing {
                self.returnFromSummon()
            }
        }
    }

    private func returnFromSummon() {
        guard isSummoned || summonedInPlace else { return }
        cancelSummonTasks()
        let landingOrigin = magnetAnchor
        removeSummonObservers()

        if summonedInPlace {
            if let landingOrigin {
                animatePanel(to: landingOrigin, curve: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .reduceMotionDefault : .summonSpring)
            }
            summonedInPlace = false
            dropInitiated = false
            sawProcessingSinceSummon = false
            if !AppState.shared.isProcessing {
                LiquidBallModel.shared.scheduleAutoTuck(afterSeconds: 1.2)
            }
            return
        }

        isSummoned = false
        dropInitiated = false
        sawProcessingSinceSummon = false

        if isTemporarySummon || !AppState.shared.floatingBallEnabled {
            dismissWithPop(destroyPanel: true)
            return
        }

        guard let anchor = dockAnchor else {
            LiquidBallModel.shared.isSummoned = false
            snapToNearestScreenEdge()
            return
        }

        let anchorRect = NSRect(origin: anchor.origin, size: CGSize(width: ballSize, height: ballSize))
        let anchorScreenExists = NSScreen.screens.contains { $0.frame.intersects(anchorRect) }
        guard anchorScreenExists else {
            dockAnchor = nil
            LiquidBallModel.shared.isSummoned = false
            snapToNearestScreenEdge()
            return
        }

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            animatePanel(
                to: anchor.origin,
                curve: .reduceMotionDefault,
                onMidpoint: {
                    LiquidBallModel.shared.dockEdge = anchor.edge
                    LiquidBallModel.shared.isSummoned = false
                },
                onComplete: { [weak self] in
                    self?.dockAnchor = nil
                    self?.saveCurrentPosition()
                    LiquidBallModel.shared.scheduleAutoTuck(afterSeconds: 1.2)
                }
            )
        } else {
            LiquidBallModel.shared.dockEdge = anchor.edge
            LiquidBallModel.shared.isSummoned = false
            animatePanel(to: anchor.origin, curve: .summonSpring, onComplete: { [weak self] in
                self?.dockAnchor = nil
                self?.saveCurrentPosition()
                LiquidBallModel.shared.scheduleAutoTuck(afterSeconds: 1.2)
            })
        }
    }

    // MARK: - Panel Origin Animation
    
    public func snapToNearestScreenEdge() {
        guard let panel = ballPanel else { return }
        let currentOrigin = panel.frame.origin
        
        // Find exact screen under the ball's center
        let ballCenter = CGPoint(x: currentOrigin.x + (ballSize / 2), y: currentOrigin.y + (ballSize / 2))
        let screen = NSScreen.screens.first(where: { NSPointInRect(ballCenter, $0.frame) }) ?? panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visibleFrame = screen.visibleFrame
        
        let dockEdge: LiquidBallModel.DockEdge = (ballCenter.x < visibleFrame.midX) ? .left : .right
        LiquidBallModel.shared.dockEdge = dockEdge
        
        let orbInset = (ballSize - Self.orbSize) / 2
        let targetX: CGFloat = (dockEdge == .left) ? visibleFrame.minX - orbInset : visibleFrame.maxX - ballSize + orbInset
        let targetY: CGFloat = max(visibleFrame.minY + 20, min(visibleFrame.maxY - ballSize - 20, currentOrigin.y))
        let targetOrigin = CGPoint(x: targetX, y: targetY)

        animatePanel(to: targetOrigin, curve: .snapDefault, onComplete: { [weak self] in
            self?.saveCurrentPosition()
            LiquidBallModel.shared.scheduleAutoTuck(afterSeconds: 1.2)
        })
    }

    private func animatePanel(
        to targetOrigin: CGPoint,
        curve: BallGlideCurve,
        onMidpoint: (@MainActor () -> Void)? = nil,
        onComplete: (@MainActor () -> Void)? = nil
    ) {
        guard let panel = ballPanel else {
            onMidpoint?()
            onComplete?()
            return
        }

        snapTimer?.invalidate()
        snapTimer = nil

        let startOrigin = panel.frame.origin
        let startTime = CACurrentMediaTime()
        var didRunMidpoint = false

        let initialSample = curve.sample(at: 0)
        panel.alphaValue = initialSample.alpha

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self = self, let panel = self.ballPanel else {
                    timer.invalidate()
                    return
                }

                let elapsed = CACurrentMediaTime() - startTime
                let sample = curve.sample(at: elapsed)

                if case .reduceMotionCrossFade = curve {
                    if sample.positionProgress >= 1.0 {
                        if !didRunMidpoint {
                            didRunMidpoint = true
                            onMidpoint?()
                            panel.setFrameOrigin(targetOrigin)
                        }
                    } else {
                        panel.setFrameOrigin(startOrigin)
                    }
                } else {
                    let curX = startOrigin.x + (targetOrigin.x - startOrigin.x) * sample.positionProgress
                    let curY = startOrigin.y + (targetOrigin.y - startOrigin.y) * sample.positionProgress
                    let origin = CGPoint(x: curX, y: curY)
                    panel.setFrameOrigin(origin)
                }

                panel.alphaValue = sample.alpha

                if sample.isSettled {
                    timer.invalidate()
                    self.snapTimer = nil
                    if !didRunMidpoint {
                        didRunMidpoint = true
                        onMidpoint?()
                    }
                    panel.setFrameOrigin(targetOrigin)
                    panel.alphaValue = sample.alpha
                    onComplete?()
                }
            }
        }
        snapTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    // MARK: - Appear / Dismiss Haptic & Animation

    private static let hapticPairGap: TimeInterval = 0.07

    private func playHapticPair(
        _ first: NSHapticFeedbackManager.FeedbackPattern,
        _ second: NSHapticFeedbackManager.FeedbackPattern
    ) {
        let generation = appearanceGeneration
        NSHapticFeedbackManager.defaultPerformer.perform(first, performanceTime: .now)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hapticPairGap) { [weak self] in
            guard let self, self.appearanceGeneration == generation else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(second, performanceTime: .now)
        }
    }

    private func cancelAppearanceAnimation() {
        appearanceGeneration &+= 1
        appearanceTimer?.invalidate()
        appearanceTimer = nil
        LiquidBallModel.shared.isDismissing = false
        if LiquidBallModel.shared.isBurst || LiquidBallModel.shared.burstProgress > 0 {
            LiquidBallModel.shared.apply(
                BallAppearanceCurve.Sample(scale: 1.0, opacity: 1.0, burstProgress: 0.0, isBurst: false, isSettled: true)
            )
        }
        if let cont = quitPopContinuation {
            quitPopContinuation = nil
            cont.resume()
        }
    }

    private func animateAppearance(
        curve: BallAppearanceCurve,
        onComplete: (@MainActor () -> Void)? = nil
    ) {
        appearanceGeneration &+= 1
        let generation = appearanceGeneration
        appearanceTimer?.invalidate()
        appearanceTimer = nil

        let model = LiquidBallModel.shared
        model.apply(curve.sample(at: 0), burstBaseScale: curve.burstBaseScale)
        let startTime = CACurrentMediaTime()

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self = self, self.appearanceGeneration == generation else {
                    timer.invalidate()
                    return
                }
                let elapsed = CACurrentMediaTime() - startTime
                let sample = curve.sample(at: elapsed)
                LiquidBallModel.shared.apply(sample, burstBaseScale: curve.burstBaseScale)

                if sample.isSettled {
                    timer.invalidate()
                    self.appearanceTimer = nil
                    onComplete?()
                }
            }
        }
        appearanceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func dismissWithPop(destroyPanel: Bool) {
        guard let panel = ballPanel, panel.isVisible else {
            cancelAppearanceAnimation()
            ballPanel?.orderOut(nil)
            ballPanel?.alphaValue = 1.0
            if destroyPanel {
                ballPanel = nil
            }
            isTemporarySummon = false
            dockAnchor = nil
            LiquidBallModel.shared.isSummoned = false
            LiquidBallModel.shared.resetAppearance()
            return
        }

        if LiquidBallModel.shared.isDismissing {
            return
        }

        snapTimer?.invalidate()
        snapTimer = nil

        let model = LiquidBallModel.shared
        model.cancelTuckTimer()
        let currentScale = max(0.05, model.appearanceScale)
        let currentOpacity = max(0.0, min(1.0, model.appearanceOpacity * panel.alphaValue))
        panel.alphaValue = 1.0

        let curve: BallAppearanceCurve = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .reduceMotionFadeOut(fromOpacity: currentOpacity)
            : .popOut(fromScale: currentScale, fromOpacity: currentOpacity)

        model.isDismissing = true
        animateAppearance(curve: curve, onComplete: { [weak self] in
            guard let self = self else { return }
            self.ballPanel?.orderOut(nil)
            self.ballPanel?.alphaValue = 1.0
            if destroyPanel {
                self.ballPanel = nil
            }
            self.isTemporarySummon = false
            self.dockAnchor = nil
            LiquidBallModel.shared.isSummoned = false
            LiquidBallModel.shared.resetAppearance()
        })
        playHapticPair(.levelChange, .alignment)
    }

    public func playQuitPop() async {
        guard let panel = ballPanel, panel.isVisible, !LiquidBallModel.shared.isDismissing else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if let existing = quitPopContinuation {
                quitPopContinuation = nil
                existing.resume()
            }
            quitPopContinuation = continuation
            LiquidBallModel.shared.cancelTuckTimer()
            LiquidBallModel.shared.isDismissing = true
            let currentScale = max(0.05, LiquidBallModel.shared.appearanceScale)
            let currentOpacity = max(0.0, min(1.0, LiquidBallModel.shared.appearanceOpacity * panel.alphaValue))
            panel.alphaValue = 1.0
            let curve = BallAppearanceCurve.popOut(fromScale: currentScale, fromOpacity: currentOpacity)
            animateAppearance(curve: curve, onComplete: { [weak self] in
                guard let self = self else { return }
                self.ballPanel?.orderOut(nil)
                self.ballPanel?.alphaValue = 1.0
                LiquidBallModel.shared.resetAppearance()
                if let cont = self.quitPopContinuation {
                    self.quitPopContinuation = nil
                    cont.resume()
                }
            })
        }
    }
    
    public func updateVisibility() {
        if AppState.shared.floatingBallEnabled {
            show()
        } else if !isTemporarySummon {
            hide()
        }
    }
    
    public func show() {
        let wasVisible = (ballPanel?.isVisible == true && !LiquidBallModel.shared.isDismissing)
        isTemporarySummon = false
        cancelAppearanceAnimation()
        if ballPanel == nil {
            createPanel()
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let appearCurve: BallAppearanceCurve = reduceMotion ? .reduceMotionFadeInDefault : .growInDefault
        if !wasVisible {
            LiquidBallModel.shared.apply(appearCurve.sample(at: 0), burstBaseScale: appearCurve.burstBaseScale)
        }

        ballPanel?.alphaValue = 1.0
        ballPanel?.level = .floating
        ballPanel?.orderFrontRegardless()
        if !isSummoned {
            LiquidBallModel.shared.isTucked = true
            snapToNearestScreenEdge()
        }
        if !wasVisible {
            animateAppearance(curve: appearCurve)
            playHapticPair(.alignment, .levelChange)
        }
    }
    
    public func hide() {
        if LiquidBallModel.shared.isDismissing {
            return
        }
        cancelSummonTasks()
        removeSummonObservers()
        snapTimer?.invalidate()
        snapTimer = nil
        isSummoned = false
        isTemporarySummon = false
        summonedInPlace = false
        dropInitiated = false
        sawProcessingSinceSummon = false
        dockAnchor = nil
        LiquidBallModel.shared.isSummoned = false
        LiquidBallModel.shared.isHovered = false
        LiquidBallModel.shared.isDropTargeted = false
        dismissWithPop(destroyPanel: false)
    }
    
    public var isBallVisible: Bool {
        ballPanel?.isVisible == true && !LiquidBallModel.shared.isDismissing
    }
    
    public func toggle() {
        if isBallVisible {
            hide()
        } else {
            show()
        }
    }
    
    public func toggleMainPopover() {
        if AppState.shared.isDetached {
            FloatingDropWindowController.shared.showFloatingWindow()
        } else {
            StatusBarController.sharedInstance?.showPopover(sender: nil)
        }
    }
    
    private func createPanel() {
        let initialRect = calculateInitialFrame()
        
        let panel = NSPanel(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = String(localized: "SqueezeBar DropBall")
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false
        panel.delegate = self
        
        let hostingView = FloatingBallHostingView(rootView: FloatingBallView())
        hostingView.frame = NSRect(x: 0, y: 0, width: ballSize, height: ballSize)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        panel.contentView = hostingView
        
        self.ballPanel = panel
    }
    
    private func calculateInitialFrame() -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        
        let savedY = UserDefaults.standard.double(forKey: Keys.ballOriginY)
        let initialY: CGFloat
        if savedY > visibleFrame.minY + 20 && savedY < visibleFrame.maxY - ballSize - 20 {
            initialY = CGFloat(savedY)
        } else {
            initialY = visibleFrame.midY - (ballSize / 2)
        }
        
        let rawEdge = UserDefaults.standard.string(forKey: Keys.dockEdge) ?? "right"
        let dockEdge = LiquidBallModel.DockEdge(rawValue: rawEdge) ?? .right
        LiquidBallModel.shared.dockEdge = dockEdge
        
        let orbInset = (ballSize - Self.orbSize) / 2
        let initialX: CGFloat = (dockEdge == .left) ? visibleFrame.minX - orbInset : visibleFrame.maxX - ballSize + orbInset
        
        return NSRect(x: initialX, y: initialY, width: ballSize, height: ballSize)
    }
}

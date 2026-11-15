import AppKit
import SwiftUI
import QuartzCore
import IslandCore

/// The hosting view keeps its final layout throughout the animation. Only the
/// silhouette changes, so text never stretches or reflows as the island opens.
@MainActor
final class LiquidPanelView: NSView {
    static let shadowInset: CGFloat = 24
    private let surface = FlippedView()
    private let silhouette = CAShapeLayer()
    private let shadowLayer = CAShapeLayer()
    private let menuBarClip = CAShapeLayer()
    let hosting: NSHostingView<IslandView>
    private(set) var outline: CGPath = CGMutablePath()
    private(set) var drawingClipRect: CGRect?
    private var contentAcceptsInput = true

    override var isFlipped: Bool { true }

    init(rootView: IslandView) {
        hosting = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        menuBarClip.fillColor = NSColor.black.cgColor
        shadowLayer.fillColor = NSColor.black.cgColor
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.32
        shadowLayer.shadowRadius = 12
        shadowLayer.shadowOffset = CGSize(width: 0, height: 7)
        layer?.addSublayer(shadowLayer)
        surface.wantsLayer = true
        surface.layer?.backgroundColor = NSColor(srgbRed: 0.025, green: 0.028, blue: 0.034, alpha: 1).cgColor
        silhouette.fillColor = NSColor.black.cgColor
        surface.layer?.mask = silhouette
        addSubview(surface)
        surface.addSubview(hosting)
        hosting.sizingOptions = []
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(rootView: IslandView, geometry: LiquidGeometry,
                contentOrigin: CGPoint? = nil, shadowProgress: Double = 1,
                surfaceOpacity: Double = 1, updateContent: Bool = true,
                contentOpacity: Double = 1, contentInteractive: Bool = true,
                menuBarClipTop: CGFloat? = nil) {
        let contentSize = CGSize(width: rootView.width, height: rootView.height)
        let origin = contentOrigin ?? CGPoint(x: Self.shadowInset, y: 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The system menu bar is translucent: lowering the window alone still
        // lets the funnel show through. Clip every fill and shadow at its edge.
        if let top = menuBarClipTop, top.isFinite {
            let scale = window?.backingScaleFactor ?? 1
            let y = min(bounds.maxY, max(bounds.minY, ceil(top * scale) / scale))
            let rect = CGRect(x: bounds.minX, y: y, width: bounds.width, height: bounds.maxY - y)
            if drawingClipRect != rect || layer?.mask !== menuBarClip {
                drawingClipRect = rect
                menuBarClip.frame = bounds
                menuBarClip.path = CGPath(rect: rect, transform: nil)
                layer?.mask = menuBarClip
            }
        } else {
            drawingClipRect = nil
            layer?.mask = nil
        }
        // The background covers the extra transparent space above menu-bar
        // content, so its mask can reach the icon without moving the window.
        if surface.frame != bounds { surface.frame = bounds }
        let contentFrame = CGRect(origin: origin, size: contentSize)
        if hosting.frame != contentFrame { hosting.frame = contentFrame }
        // Menu-bar ticks only update the mask and cached view opacity. Replacing
        // rootView every frame invalidates the entire SwiftUI content tree.
        if updateContent { hosting.rootView = rootView }
        hosting.alphaValue = contentOpacity.isFinite ? min(1, max(0, contentOpacity)) : 0
        contentAcceptsInput = contentInteractive
        hosting.setAccessibilityHidden(!contentInteractive)
        silhouette.frame = surface.bounds
        var shift = CGAffineTransform(translationX: origin.x, y: origin.y)
        outline = geometry.path.copy(using: &shift) ?? geometry.path
        silhouette.path = outline
        shadowLayer.frame = bounds
        shadowLayer.path = outline
        shadowLayer.shadowPath = outline
        let shadow = shadowProgress.isFinite ? min(1, max(0, shadowProgress)) : 0
        shadowLayer.shadowOpacity = 0.32 * Float(shadow)
        shadowLayer.shadowRadius = 12 * CGFloat(shadow)
        shadowLayer.shadowOffset = CGSize(width: 0, height: 7 * shadow)
        let opacity = surfaceOpacity.isFinite ? min(1, max(0, surfaceOpacity)) : 0
        surface.alphaValue = opacity
        // This layer also fills the silhouette beneath the content surface.
        // Fade both fills so the final intake cannot leave a black remnant.
        shadowLayer.opacity = Float(opacity)
        CATransaction.commit()
    }

    func containsScreenPoint(_ point: CGPoint) -> Bool {
        guard let window else { return false }
        return containsVisiblePoint(convert(window.convertPoint(fromScreen: point), from: nil))
    }

    private func containsVisiblePoint(_ point: CGPoint) -> Bool {
        if let drawingClipRect, !drawingClipRect.contains(point) { return false }
        return outline.contains(point)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // NSView hitTest receives a point in its superview's coordinates.
        guard containsVisiblePoint(convert(point, from: superview)) else { return nil }
        guard contentAcceptsInput else { return self }
        return super.hitTest(point)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class IslandMotionDriver {
    private(set) var spring = LiquidSpring()
    var onFrame: ((Double) -> Void)?
    private(set) var menuBarAnimation = false
    private var menuBarProgress: Double = 0
    private var menuBarTarget: Double = 0
    private var menuBarOpeningTime: Double = 0
    var progress: Double { menuBarAnimation ? menuBarProgress : spring.value }
    var target: Double { menuBarAnimation ? menuBarTarget : spring.target }
    private var timer: Timer?
    private var lastTime: CFTimeInterval = 0

    func setExpanded(_ expanded: Bool, reduceMotion: Bool, menuBar: Bool = false) {
        let destination = expanded ? 1.0 : 0.0
        if menuBarAnimation != menuBar {
            let current = progress
            stop()
            spring.snap(to: current)
            menuBarProgress = current
            menuBarTarget = current
            menuBarOpeningTime = MenuBarCollapse.openingTime(for: current)
            menuBarAnimation = menuBar
        }
        if reduceMotion { snap(to: destination); return }
        guard target != destination || timer == nil && progress != destination else { return }
        if menuBar {
            // Invert the opening curve when reversing so the visible outline
            // stays in place; repeated layout updates must not restart time.
            menuBarOpeningTime = MenuBarCollapse.openingTime(for: menuBarProgress)
            menuBarTarget = destination
            if timer != nil { lastTime = CACurrentMediaTime() }
        }
        else { spring.setTarget(destination) }
        guard timer == nil else { return }
        lastTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.001
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let elapsed = now - lastTime
        lastTime = now
        advance(deltaTime: elapsed)
    }

    /// The menu-bar transition follows elapsed time even if a frame is missed.
    /// Only the notch/floating spring retains its integration step cap.
    func advance(deltaTime: Double) {
        let moving: Bool
        if menuBarAnimation {
            guard deltaTime.isFinite, deltaTime > 0 else { return }
            if menuBarTarget == 1 {
                menuBarOpeningTime = min(1, menuBarOpeningTime + deltaTime / MenuBarCollapse.openingDuration)
                menuBarProgress = MenuBarCollapse.openingProgress(menuBarOpeningTime)
            } else {
                menuBarProgress = max(0, menuBarProgress - deltaTime / MenuBarCollapse.duration)
            }
            if abs(menuBarProgress - menuBarTarget) < 0.0000001 { menuBarProgress = menuBarTarget }
            moving = menuBarProgress != menuBarTarget
        } else {
            moving = spring.advance(deltaTime: deltaTime)
        }
        onFrame?(progress)
        if !moving { stop() }
    }

    func snap(to value: Double) {
        stop()
        spring.snap(to: value)
        menuBarProgress = spring.value
        menuBarTarget = spring.value
        menuBarOpeningTime = MenuBarCollapse.openingTime(for: spring.value)
        onFrame?(progress)
    }

    func stop() { timer?.invalidate(); timer = nil }
}

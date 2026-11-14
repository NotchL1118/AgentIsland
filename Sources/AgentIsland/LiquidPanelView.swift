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
    let hosting: NSHostingView<IslandView>
    private(set) var outline: CGPath = CGMutablePath()

    override var isFlipped: Bool { true }

    init(rootView: IslandView) {
        hosting = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
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

    func update(rootView: IslandView, geometry: LiquidGeometry) {
        let contentSize = CGSize(width: rootView.width, height: rootView.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.frame = CGRect(origin: CGPoint(x: Self.shadowInset, y: 0), size: contentSize)
        hosting.frame = surface.bounds
        hosting.rootView = rootView
        silhouette.frame = surface.bounds
        silhouette.path = geometry.path
        var shift = CGAffineTransform(translationX: Self.shadowInset, y: 0)
        outline = geometry.path.copy(using: &shift) ?? geometry.path
        shadowLayer.frame = bounds
        shadowLayer.path = outline
        shadowLayer.shadowPath = outline
        CATransaction.commit()
    }

    func containsScreenPoint(_ point: CGPoint) -> Bool {
        guard let window else { return false }
        return outline.contains(convert(window.convertPoint(fromScreen: point), from: nil))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // NSView hitTest receives a point in its superview's coordinates.
        guard outline.contains(convert(point, from: superview)) else { return nil }
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
    private var timer: Timer?
    private var lastTime: CFTimeInterval = 0

    func setExpanded(_ expanded: Bool, reduceMotion: Bool) {
        let target = expanded ? 1.0 : 0.0
        if reduceMotion { snap(to: target); return }
        guard spring.target != target || timer == nil && spring.value != target else { return }
        spring.setTarget(target)
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
        let moving = spring.advance(deltaTime: now - lastTime)
        lastTime = now
        onFrame?(spring.value)
        if !moving { stop() }
    }

    func snap(to value: Double) {
        stop()
        spring.snap(to: value)
        onFrame?(spring.value)
    }

    func stop() { timer?.invalidate(); timer = nil }
}

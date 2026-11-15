import AppKit
import IslandCore

/// Updates only the native button image while running; animation frames never
/// trigger a panel layout or expose session content in the menu bar.
@MainActor
final class MenuBarStatusPresenter {
    private weak var button: NSStatusBarButton?
    private var timer: Timer?
    private(set) var activity: MenuBarActivity = .idle
    private(set) var frameIndex = 0
    var isAnimating: Bool { timer != nil }

    init(button: NSStatusBarButton) {
        self.button = button
    }

    func update(activity: MenuBarActivity, pendingCount: Int, menuBarOnly: Bool, reduceMotion: Bool) {
        guard let button else { stop(); return }
        // Other presentations retain their existing pending-count shortcut.
        button.title = !menuBarOnly && pendingCount > 0 ? " \(pendingCount)" : ""
        button.imagePosition = button.title.isEmpty ? .imageOnly : .imageLeft
        let label = activity.accessibilityLabel
            + (activity == .running && pendingCount > 0 ? " · 有待处理任务" : "")
        button.toolTip = "\(label) · 点击展开，右键设置"
        button.setAccessibilityLabel("Agent Island · \(label)")

        if self.activity != activity {
            stop()
            self.activity = activity
        }
        guard activity == .running && !reduceMotion else {
            stop()
            button.image = Self.staticImage(for: activity)
            return
        }
        // Model changes (including heartbeats) must not restart the animation.
        guard timer == nil else { return }
        button.image = Self.runningFrames[frameIndex]
        let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceFrame() }
        }
        timer.tolerance = 0.015
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func advanceFrame() {
        guard let button else { stop(); return }
        frameIndex = (frameIndex + 1) % Self.runningFrames.count
        button.image = Self.runningFrames[frameIndex]
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        frameIndex = 0
    }

    deinit { timer?.invalidate() }

    // All states use the same canvas so the status item and panel anchor stay
    // fixed as the glyph changes. Templates follow the system bar appearance.
    static let imageSize = NSSize(width: 18, height: 18)
    static let runningFrames: [NSImage] = (0..<24).map { frame in
        let phase = Double(frame) / 24 * 2 * Double.pi
        let image = NSImage(size: imageSize, flipped: false) { _ in
            NSColor.black.setFill()
            for bar in 0..<5 {
                let envelope = [6.0, 10.0, 14.0, 10.0, 6.0][bar]
                let wave = (sin(phase + Double(bar) * 0.9) + 1) / 2
                let height = 3 + (envelope - 3) * (0.25 + 0.75 * wave)
                let rect = NSRect(x: 1 + Double(bar) * 3.5, y: (18 - height) / 2,
                                  width: 2, height: height)
                NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static let symbols: [String: NSImage] = {
        let names = ["waveform", "ellipsis.circle", "exclamationmark.circle",
                     "xmark.circle", "questionmark.circle", "checkmark.circle"]
        return Dictionary(uniqueKeysWithValues: names.compactMap { name in
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .medium)) else { return nil }
            let image = NSImage(size: imageSize, flipped: false) { bounds in
                let scale = min(1, min(bounds.width / symbol.size.width, bounds.height / symbol.size.height))
                let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
                symbol.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                      width: size.width, height: size.height))
                return true
            }
            image.isTemplate = true
            return (name, image)
        })
    }()

    static func staticImage(for activity: MenuBarActivity) -> NSImage? {
        let name: String
        switch activity {
        case .idle: name = "waveform"
        case .running: name = "ellipsis.circle"
        case .needsAttention: name = "exclamationmark.circle"
        case .failed: name = "xmark.circle"
        case .disconnected: name = "questionmark.circle"
        case .completed: name = "checkmark.circle"
        }
        return symbols[name]
    }
}

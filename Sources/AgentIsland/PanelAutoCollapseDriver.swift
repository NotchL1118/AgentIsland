import Foundation
import IslandCore

@MainActor
final class PanelAutoCollapseDriver {
    struct Context {
        var expanded: Bool
        var presentation: IslandPresentation
        var pointerInside: Bool
        var isDragging: Bool
        var delay: TimeInterval
    }

    var context: (() -> Context?)?
    var onCollapse: (() -> Void)?
    private var policy = PanelAutoCollapse()
    private var timer: Timer?
    private var scheduledDeadline: TimeInterval?

    func update(outsideClick: Bool = false) {
        guard let context = context?() else { reset(); return }
        let now = ProcessInfo.processInfo.systemUptime
        if policy.update(now: now, expanded: context.expanded, presentation: context.presentation,
                         pointerInside: context.pointerInside, isDragging: context.isDragging,
                         delay: context.delay, outsideClick: outsideClick) {
            reset()
            onCollapse?()
            return
        }
        guard let deadline = policy.pending?.deadline else { cancelTimer(); return }
        guard scheduledDeadline != deadline else { return }
        cancelTimer()
        scheduledDeadline = deadline
        let timer = Timer(timeInterval: max(0.001, deadline - now), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelTimer()
                self?.update()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func reset() { cancelTimer(); policy.reset() }
    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
        scheduledDeadline = nil
    }
}

import AppKit
import QuartzCore

/// One display link for everything that moves every frame: the playhead, the meters
/// and the position display. They update Core Animation layers directly, because
/// redrawing SwiftUI views every frame costs far more (the spike measured about 19%
/// of a core for one counter and meter).
@MainActor
final class FrameClock: NSObject {
    static let shared = FrameClock()

    private var link: CADisplayLink?
    private var subscribers: [UUID: () -> Void] = [:]

    func subscribe(_ action: @escaping () -> Void) -> UUID {
        let id = UUID()
        subscribers[id] = action
        startIfNeeded()
        return id
    }

    func unsubscribe(_ id: UUID?) {
        guard let id else { return }
        subscribers[id] = nil
    }

    private func startIfNeeded() {
        guard link == nil, let screen = NSScreen.main else { return }
        let newLink = screen.displayLink(target: self, selector: #selector(tick(_:)))
        newLink.add(to: .main, forMode: .common)
        link = newLink
    }

    @objc private func tick(_ link: CADisplayLink) {
        for action in subscribers.values {
            action()
        }
    }
}

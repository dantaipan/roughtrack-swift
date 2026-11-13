import AppKit

/// The zoom and horizontal scroll the ruler and lanes share.
@MainActor
final class TimelineGeometry {
    static let minimumZoom: CGFloat = 4      // pixels per second
    static let maximumZoom: CGFloat = 2000

    private(set) var pixelsPerSecond: CGFloat = 40
    private(set) var scrollX: CGFloat = 0
    var sampleRate: Double = 48000
    var tempo: Double = 120

    private var observers: [UUID: (_ zoomChanged: Bool) -> Void] = [:]

    func observe(_ action: @escaping (_ zoomChanged: Bool) -> Void) -> UUID {
        let id = UUID()
        observers[id] = action
        return id
    }

    func stopObserving(_ id: UUID?) {
        guard let id else { return }
        observers[id] = nil
    }

    /// Where a sample is in a view showing the timeline from its left edge.
    func x(forSample sample: Int64) -> CGFloat {
        contentX(forSample: sample) - scrollX
    }

    /// Where a sample is on the whole timeline, before scrolling.
    func contentX(forSample sample: Int64) -> CGFloat {
        CGFloat(Double(sample) / sampleRate) * pixelsPerSecond
    }

    func sample(forX x: CGFloat) -> Int64 {
        Int64(((x + scrollX) / pixelsPerSecond) * CGFloat(sampleRate))
    }

    func samples(forPixels pixels: CGFloat) -> Int64 {
        Int64((pixels / pixelsPerSecond) * CGFloat(sampleRate))
    }

    var secondsPerBar: Double { 4 * 60 / tempo }

    func scroll(by delta: CGFloat) {
        let newScroll = max(0, scrollX + delta)
        guard newScroll != scrollX else { return }
        scrollX = newScroll
        notify(zoomChanged: false)
    }

    /// Zooms keeping the time under `anchorX` where it is.
    func zoom(by factor: CGFloat, around anchorX: CGFloat) {
        let newZoom = min(max(pixelsPerSecond * factor, Self.minimumZoom), Self.maximumZoom)
        guard newZoom != pixelsPerSecond else { return }
        let seconds = (anchorX + scrollX) / pixelsPerSecond
        pixelsPerSecond = newZoom
        scrollX = max(0, seconds * newZoom - anchorX)
        notify(zoomChanged: true)
    }

    func timingChanged() {
        notify(zoomChanged: true)
    }

    private func notify(zoomChanged: Bool) {
        for action in observers.values {
            action(zoomChanged)
        }
    }
}

/// Scroll and zoom gestures shared by the ruler and lanes: horizontal swipes or
/// Shift-scroll move along, Command-scroll and pinch zoom, and anything else goes
/// to the enclosing vertical scroll view. Returns false for that last case.
@MainActor
func handleTimelineScroll(_ event: NSEvent, in view: NSView, geometry: TimelineGeometry) -> Bool {
    let location = view.convert(event.locationInWindow, from: nil)

    if event.modifierFlags.contains(.command) {
        geometry.zoom(by: pow(1.01, event.scrollingDeltaY), around: location.x)
        return true
    }

    if event.modifierFlags.contains(.shift) {
        let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
        geometry.scroll(by: -delta)
        return true
    }

    if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
        geometry.scroll(by: -event.scrollingDeltaX)
        return true
    }

    return false
}

/// A menu item that runs a closure, for menus built in code.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

extension NSMenu {
    /// A menu whose items don't follow the responder chain, so `isEnabled` holds.
    static func manual(_ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        items.forEach { menu.addItem($0) }
        return menu
    }
}

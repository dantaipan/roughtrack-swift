import AppKit
import QuartzCore
import SwiftUI

/// The scroll bar under the lanes. It shows where the view is along the timeline and moves
/// it when the knob is dragged, the track is clicked, or a plain scroll wheel turns over it,
/// so a mouse without a sideways wheel can move along too.
final class TimelineScrollerNSView: NSView {
    static let height: CGFloat = 14
    private static let inset: CGFloat = 3
    private static let minimumKnob: CGFloat = 24

    /// Room past the last part, so there's somewhere to record into.
    private static let barsPastEnd: Double = 8

    private let geometry: TimelineGeometry
    private var observer: UUID?
    private let knob = CALayer()

    /// Where the last part ends, in samples.
    var timelineEnd: Int64 = 0 {
        didSet { if timelineEnd != oldValue { moveKnob() } }
    }

    private var knobDrag: (startX: CGFloat, startScroll: CGFloat, pixelsPerPoint: CGFloat)?

    init(geometry: TimelineGeometry) {
        self.geometry = geometry
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.ruler.cgColor

        knob.backgroundColor = Theme.scrollerKnob.cgColor
        knob.cornerRadius = (Self.height - 2 * Self.inset) / 2
        layer?.addSublayer(knob)

        observer = geometry.observe { [weak self] _ in self?.moveKnob() }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        let observer = observer, geometry = geometry
        MainActor.assumeIsolated { geometry.stopObserving(observer) }
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        moveKnob()
    }

    // MARK: Geometry

    private var visibleWidth: CGFloat { max(bounds.width, 1) }
    private var trackWidth: CGFloat { max(bounds.width - 2 * Self.inset, 1) }

    /// How wide the timeline is: past the last part by a few bars, and always as far as
    /// the view has been scrolled.
    private var contentWidth: CGFloat {
        let pastEnd = CGFloat(geometry.secondsPerBar * Self.barsPastEnd) * geometry.pixelsPerSecond
        return max(geometry.contentX(forSample: timelineEnd) + pastEnd, geometry.scrollX + visibleWidth)
    }

    private var knobFrame: CGRect {
        let content = contentWidth
        let width = min(trackWidth, max(Self.minimumKnob, trackWidth * visibleWidth / content))
        let travel = trackWidth - width
        let scrollable = content - visibleWidth
        let x = Self.inset + (scrollable > 0 ? travel * geometry.scrollX / scrollable : 0)
        return CGRect(x: x, y: Self.inset, width: width, height: bounds.height - 2 * Self.inset)
    }

    private func moveKnob() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        knob.frame = knobFrame
        CATransaction.commit()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let frame = knobFrame

        if frame.minX...frame.maxX ~= x {
            // Fixed for the drag, so the knob stays under the mouse as the content grows.
            let travel = trackWidth - frame.width
            let ratio = travel > 0 ? (contentWidth - visibleWidth) / travel : 0
            knobDrag = (x, geometry.scrollX, ratio)
        } else {
            // A click beside the knob turns a page that way.
            geometry.scroll(by: (x < frame.minX ? -1 : 1) * visibleWidth * 0.9)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag = knobDrag else { return }
        let x = convert(event.locationInWindow, from: nil).x
        geometry.scroll(to: drag.startScroll + (x - drag.startX) * drag.pixelsPerPoint)
    }

    override func mouseUp(with event: NSEvent) {
        knobDrag = nil
    }

    override func scrollWheel(with event: NSEvent) {
        if handleTimelineScroll(event, in: self, geometry: geometry) { return }
        // Over the scroll bar, a plain wheel moves along the timeline.
        geometry.scroll(by: -event.scrollingDeltaY)
    }
}

struct TimelineScroller: NSViewRepresentable {
    let geometry: TimelineGeometry
    @EnvironmentObject private var model: StudioModel

    func makeNSView(context: Context) -> TimelineScrollerNSView {
        TimelineScrollerNSView(geometry: geometry)
    }

    func updateNSView(_ view: TimelineScrollerNSView, context: Context) {
        view.timelineEnd = model.clips.values.joined()
            .map { $0.looping ? max($0.end, $0.loopEnd) : $0.end }
            .max() ?? 0
    }
}

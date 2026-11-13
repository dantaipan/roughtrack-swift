import AppKit
import QuartzCore
import RoughTrackCore
import SwiftUI

/// Bar numbers, the playhead marker and the loop range. The top half moves the playhead
/// on a click. The bottom half marks a loop by dragging, or drags the loop's edges or
/// middle, and a click there that doesn't drag moves the playhead too.
final class RulerNSView: NSView {
    private enum CycleDrag {
        case pending, create, start, end, move
    }

    private let geometry: TimelineGeometry
    private var observer: UUID?
    private var clockSubscription: UUID?
    private let playheadMarker = CAShapeLayer()

    weak var model: StudioModel?

    private var cycleDrag: CycleDrag?
    private var dragStartX: CGFloat = 0
    private var cycleOriginal: (start: Int64, end: Int64) = (0, 0)
    private var cyclePreview: (start: Int64, end: Int64)?

    init(geometry: TimelineGeometry) {
        self.geometry = geometry
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.ruler.cgColor
        // Since macOS 14 views don't clip by default, and bar numbers scrolled past the
        // left edge would draw over the track list's header.
        clipsToBounds = true

        let path = CGMutablePath()
        path.move(to: CGPoint(x: -6, y: 0))
        path.addLine(to: CGPoint(x: 6, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 8))
        path.closeSubpath()
        playheadMarker.path = path
        playheadMarker.fillColor = Theme.playhead.cgColor
        playheadMarker.zPosition = 5
        layer?.addSublayer(playheadMarker)

        observer = geometry.observe { [weak self] _ in self?.needsDisplay = true }
        clockSubscription = FrameClock.shared.subscribe { [weak self] in self?.movePlayhead() }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        let observer = observer, subscription = clockSubscription, geometry = geometry
        MainActor.assumeIsolated {
            geometry.stopObserving(observer)
            FrameClock.shared.unsubscribe(subscription)
        }
    }

    override var isFlipped: Bool { true }

    private var bottomHalf: CGFloat { bounds.height / 2 }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        Theme.ruler.setFill()
        bounds.fill()

        drawCycle()

        Theme.separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

        let barWidth = CGFloat(geometry.secondsPerBar) * geometry.pixelsPerSecond
        guard barWidth > 0 else { return }

        // Label every bar, or every 2nd, 4th, 8th... so the numbers don't crowd.
        var labelEvery = 1
        while barWidth * CGFloat(labelEvery) < 44 { labelEvery *= 2 }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: Theme.secondaryText,
        ]

        let firstBar = max(0, Int(geometry.scrollX / barWidth))
        let lastBar = Int((geometry.scrollX + bounds.width) / barWidth) + 1

        for bar in firstBar...lastBar {
            let x = CGFloat(bar) * barWidth - geometry.scrollX
            let isLabelled = bar % labelEvery == 0
            Theme.secondaryText.withAlphaComponent(isLabelled ? 0.7 : 0.3).setFill()
            NSRect(x: x, y: isLabelled ? 3 : 8, width: 1, height: isLabelled ? 9 : 4).fill()

            if isLabelled {
                NSString(string: "\(bar + 1)").draw(at: CGPoint(x: x + 3, y: 0), withAttributes: attributes)
            }
        }
    }

    private var shownCycle: (start: Int64, end: Int64)? {
        if let cyclePreview { return cyclePreview }
        guard let model, model.cycleEnd > model.cycleStart else { return nil }
        return (model.cycleStart, model.cycleEnd)
    }

    private func drawCycle() {
        guard let cycle = shownCycle else { return }
        let x1 = geometry.x(forSample: cycle.start)
        let x2 = geometry.x(forSample: cycle.end)
        let enabled = (model?.cycleEnabled ?? false) || cyclePreview != nil
        let colour = enabled ? Theme.cycle : Theme.secondaryText

        let band = NSRect(x: x1, y: bottomHalf + 1, width: x2 - x1, height: bottomHalf - 3)
        colour.withAlphaComponent(enabled ? 0.85 : 0.35).setFill()
        NSBezierPath(roundedRect: band, xRadius: 2, yRadius: 2).fill()
    }

    private func movePlayhead() {
        guard let position = rt.app()?.position() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playheadMarker.position = CGPoint(x: geometry.x(forSample: position), y: bounds.height - 9)
        playheadMarker.isHidden = playheadMarker.position.x < -6 || playheadMarker.position.x > bounds.width + 6
        CATransaction.commit()
    }

    // MARK: Mouse

    private func cycleZone(at point: CGPoint) -> CycleDrag {
        guard let model, model.cycleEnd > model.cycleStart else { return .pending }
        let x1 = geometry.x(forSample: model.cycleStart)
        let x2 = geometry.x(forSample: model.cycleEnd)

        if abs(point.x - x1) <= 5 { return .start }
        if abs(point.x - x2) <= 5 { return .end }
        return point.x > x1 && point.x < x2 ? .move : .pending
    }

    override func resetCursorRects() {
        guard let model, model.cycleEnd > model.cycleStart else { return }
        for sample in [model.cycleStart, model.cycleEnd] {
            let x = geometry.x(forSample: sample)
            addCursorRect(NSRect(x: x - 5, y: bottomHalf, width: 10, height: bottomHalf), cursor: .resizeLeftRight)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // The top half moves the playhead at once.
        guard point.y >= bottomHalf else {
            model?.seek(to: max(0, geometry.sample(forX: point.x)))
            return
        }

        cycleDrag = cycleZone(at: point)
        dragStartX = point.x
        cycleOriginal = (model?.cycleStart ?? 0, model?.cycleEnd ?? 0)
        cyclePreview = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag = cycleDrag, let app = rt.app() else { return }
        let point = convert(event.locationInWindow, from: nil)
        let free = event.modifierFlags.contains(.command)

        if drag == .pending {
            guard abs(point.x - dragStartX) >= 3 else { return }
            cycleDrag = .create
        }

        let distance = geometry.samples(forPixels: point.x - dragStartX)
        let beat = app.samplesPerBeat()
        let gridStep: Int64
        switch free ? .off : (model?.snap ?? .bar) {
        case .bar: gridStep = Int64(beat * 4)
        case .beat: gridStep = Int64(beat)
        case .sixteenth: gridStep = Int64(beat / 4)
        default: gridStep = 0
        }
        let shortest = max(app.minimumCycleLength(), gridStep)
        let snap = { (sample: Int64) in app.snapPosition(sample, free) }
        let original = cycleOriginal

        switch cycleDrag {
        case .create:
            let from = snap(geometry.sample(forX: dragStartX))
            let to = snap(geometry.sample(forX: point.x))
            let start = min(from, to)
            cyclePreview = (start, max(max(from, to), start + shortest))
        case .start:
            cyclePreview = (min(snap(original.start + distance), original.end - shortest), original.end)
        case .end:
            cyclePreview = (original.start, max(snap(original.end + distance), original.start + shortest))
        case .move:
            let start = snap(original.start + distance)
            cyclePreview = (start, start + original.end - original.start)
        default:
            break
        }

        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag = cycleDrag else { return }
        cycleDrag = nil

        if let preview = cyclePreview, preview != cycleOriginal || drag == .create {
            model?.setCycle(preview.start, preview.end)
        } else {
            // A press that never became a drag is a click, which moves the playhead.
            model?.seek(to: max(0, geometry.sample(forX: dragStartX)))
        }

        cyclePreview = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let model, model.cycleEnd > model.cycleStart else { return nil }
        return NSMenu.manual([ActionMenuItem("Clear Loop") { [weak model] in model?.clearCycle() }])
    }

    override func scrollWheel(with event: NSEvent) {
        if !handleTimelineScroll(event, in: self, geometry: geometry) {
            super.scrollWheel(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        geometry.zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil).x)
    }
}

struct RulerView: NSViewRepresentable {
    let geometry: TimelineGeometry
    @EnvironmentObject private var model: StudioModel

    func makeNSView(context: Context) -> RulerNSView {
        let view = RulerNSView(geometry: geometry)
        view.model = model
        return view
    }

    func updateNSView(_ view: RulerNSView, context: Context) {
        // Reading these makes SwiftUI call this again when the loop changes.
        _ = (model.cycleStart, model.cycleEnd, model.cycleEnabled)
        view.needsDisplay = true
        view.window?.invalidateCursorRects(for: view)
    }
}

import AppKit
import QuartzCore
import RoughTrackCore
import SwiftUI

/// A strobe tuner under the control bar, as RoughTrack has: the bands drift right when a
/// string is sharp and left when it's flat, and stand still in tune. It reads the core each
/// frame and moves Core Animation layers, never SwiftUI state.
final class TunerNSView: NSView {
    static let height: CGFloat = 54

    private static let barWidth: CGFloat = 28
    private static let centsToBarsPerSecond = 0.25
    private static let inTuneCents = 1.0
    private static let noteWidth: CGFloat = 96
    private static let sourceWidth: CGFloat = 200

    private let note = CATextLayer()
    private let cents = CATextLayer()
    private let source = CATextLayer()
    private let band = CALayer()
    private let stripes = CAReplicatorLayer()
    private let stripe = CALayer()
    private let centre = CALayer()

    private var subscription: UUID?
    private var phase: CGFloat = 0
    private var lastTime = CACurrentMediaTime()
    private var shown: (note: String, cents: Int, source: String, inTune: Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.display.cgColor

        for text in [note, cents, source] {
            text.contentsScale = 2
            text.foregroundColor = Theme.displayText.cgColor
            layer?.addSublayer(text)
        }

        note.fontSize = 30
        note.font = NSFont.systemFont(ofSize: 30, weight: .semibold)
        note.alignmentMode = .center
        cents.fontSize = 12
        cents.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        cents.alignmentMode = .center
        source.fontSize = 11
        source.foregroundColor = Theme.secondaryText.cgColor
        source.alignmentMode = .right
        source.truncationMode = .end

        band.masksToBounds = true
        band.cornerRadius = 4
        band.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        layer?.addSublayer(band)

        stripe.backgroundColor = Theme.secondaryText.withAlphaComponent(0.5).cgColor
        stripes.addSublayer(stripe)
        stripes.instanceTransform = CATransform3DMakeTranslation(Self.barWidth * 2, 0, 0)
        band.addSublayer(stripes)

        centre.backgroundColor = Theme.playhead.cgColor
        layer?.addSublayer(centre)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window != nil, subscription == nil {
            rt.app()?.startTuner()
            lastTime = CACurrentMediaTime()
            subscription = FrameClock.shared.subscribe { [weak self] in self?.frame() }
        } else if window == nil, subscription != nil {
            FrameClock.shared.unsubscribe(subscription)
            subscription = nil
            rt.app()?.stopTuner()
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        note.frame = CGRect(x: 0, y: 4, width: Self.noteWidth, height: 38)
        cents.frame = CGRect(x: 0, y: bounds.height - 18, width: Self.noteWidth, height: 16)
        let bandFrame = CGRect(x: Self.noteWidth, y: 10, width: max(0, bounds.width - Self.noteWidth - Self.sourceWidth - 16), height: bounds.height - 20)
        band.frame = bandFrame
        stripe.frame = CGRect(x: 0, y: 0, width: Self.barWidth, height: bandFrame.height)
        stripes.instanceCount = Int(bandFrame.width / (Self.barWidth * 2)) + 3
        centre.frame = CGRect(x: bandFrame.midX - 1, y: 6, width: 2, height: bounds.height - 12)
        source.frame = CGRect(x: bounds.width - Self.sourceWidth - 8, y: bounds.height / 2 - 8, width: Self.sourceWidth, height: 16)
        CATransaction.commit()
    }

    override var isFlipped: Bool { true }

    private func frame() {
        guard let app = rt.app() else { return }
        let reading = app.tuner()
        let now = CACurrentMediaTime()
        let elapsed = now - lastTime
        lastTime = now

        let noteName = reading.hasNote ? String(reading.note) : "–"
        let centsValue = Int(reading.cents.rounded())
        let inTune = reading.hasNote && abs(reading.cents) <= Self.inTuneCents
        let sourceName = String(reading.source)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if shown?.note != noteName || shown?.cents != centsValue || shown?.source != sourceName || shown?.inTune != inTune {
            note.string = noteName
            note.foregroundColor = (inTune ? Theme.play : Theme.displayText).cgColor
            cents.string = reading.hasNote ? (centsValue > 0 ? "+\(centsValue) cents" : "\(centsValue) cents") : ""
            source.string = sourceName
            stripe.backgroundColor = (inTune ? Theme.play : Theme.secondaryText).withAlphaComponent(reading.hasNote ? 0.6 : 0.2).cgColor
            shown = (noteName, centsValue, sourceName, inTune)
        }

        // The bands move by the cents off, so they stand still in tune.
        if reading.hasNote {
            phase += CGFloat(reading.cents * Self.centsToBarsPerSecond * elapsed) * Self.barWidth
            phase = phase.truncatingRemainder(dividingBy: Self.barWidth * 2)
        }
        stripes.frame = CGRect(x: phase - Self.barWidth * 2, y: 0, width: band.bounds.width + Self.barWidth * 4, height: band.bounds.height)

        CATransaction.commit()
    }
}

struct TunerStrip: NSViewRepresentable {
    func makeNSView(context: Context) -> TunerNSView { TunerNSView() }
    func updateNSView(_ view: TunerNSView, context: Context) {}
}

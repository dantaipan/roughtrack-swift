import AppKit
import QuartzCore
import RoughTrackCore
import SwiftUI

/// The transport buttons and position display, centred in the window's toolbar.
struct ControlBar: View {
    @EnvironmentObject private var model: StudioModel

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 2) {
                TransportButton(symbol: "backward.end.fill", help: "Go to Beginning (Return)") { model.returnToStart() }
                TransportButton(symbol: "play.fill", help: "Play (Space)",
                                tint: model.transport == .playing ? Theme.play : nil) { model.play() }
                TransportButton(symbol: "stop.fill", help: "Stop (Space)") { model.stop() }
                TransportButton(symbol: "record.circle", help: "Record (R)",
                                tint: model.transport == .recording ? Theme.record : nil) { model.record() }
            }

            PositionDisplay()
                .frame(width: 250, height: 32)
                .overlay(alignment: .trailing) {
                    // The tempo part of the display opens a field to change it.
                    Button { showingTempo = true } label: { Color.clear.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .frame(width: 110, height: 16)
                        .offset(y: 7)
                        .help("Set the tempo")
                        .popover(isPresented: $showingTempo, arrowEdge: .bottom) { TempoEditor() }
                }

            HStack(spacing: 6) {
                TransportButton(symbol: "repeat", help: "Loop (L)",
                                tint: model.cycleEnabled ? Theme.cycle : nil) { model.toggleCycle() }
                TransportButton(symbol: "metronome", help: "Click (K)",
                                tint: model.clickEnabled ? Theme.cycle : nil) { model.toggleClick() }

                Picker("Snap", selection: Binding(get: { model.snap }, set: { model.setSnap($0) })) {
                    Text("Bar").tag(rt.Snap.bar)
                    Text("Beat").tag(rt.Snap.beat)
                    Text("1/16").tag(rt.Snap.sixteenth)
                    Text("Off").tag(rt.Snap.off)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 70)
                .help("Snap: what moves, trims and loops land on. Hold Command to place freely.")

                TransportButton(symbol: "slider.vertical.3", help: "Mixer (X)",
                                tint: model.showingMixer ? Theme.mute : nil) { model.showingMixer.toggle() }
                TransportButton(symbol: "tuningfork", help: "Tuner (⌘U)",
                                tint: model.showingTuner ? Theme.play : nil) { model.showingTuner.toggle() }
                TransportButton(symbol: "square.grid.3x3", help: "Grooves (G)",
                                tint: model.showingGrooves ? Theme.colour(for: .drums) : nil) { model.showingGrooves.toggle() }
            }
        }
    }

    @State private var showingTempo = false
}

/// A field and stepper for the tempo, in a popover from the display.
private struct TempoEditor: View {
    @EnvironmentObject private var model: StudioModel
    @State private var text = ""

    var body: some View {
        HStack(spacing: 8) {
            Text("Tempo")
            TextField("BPM", text: $text)
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
                .onSubmit(apply)
            Stepper("", value: Binding(get: { model.tempo }, set: { model.setTempo($0.rounded()); text = format($0.rounded()) }),
                    in: 20...300, step: 1)
                .labelsHidden()
            Text("bpm").foregroundStyle(Color(Theme.secondaryText))
        }
        .padding(12)
        .onAppear {
            text = format(model.tempo)
            model.isEditingText = true
        }
        .onDisappear {
            apply()
            model.isEditingText = false
        }
    }

    private func format(_ tempo: Double) -> String {
        tempo == tempo.rounded() ? String(Int(tempo)) : String(format: "%.1f", tempo)
    }

    private func apply() {
        if let value = Double(text.replacingOccurrences(of: ",", with: ".")), value != model.tempo {
            model.setTempo(value)
        }
    }
}

private struct TransportButton: View {
    let symbol: String
    let help: String
    var tint: NSColor?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint.map { Color($0) } ?? Color(Theme.text))
                .frame(width: 34, height: 26)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

// MARK: - Position display

/// Bars and beats, time and tempo, like a hardware display. Its text layers change only
/// when what they show changes, a few times a second, so it costs almost nothing.
final class PositionDisplayNSView: NSView {
    private let barsLayer = CATextLayer()
    private let timeLayer = CATextLayer()
    private let tempoLayer = CATextLayer()
    private var subscription: UUID?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.display.cgColor
        layer?.cornerRadius = 6

        for text in [barsLayer, timeLayer, tempoLayer] {
            text.foregroundColor = Theme.displayText.cgColor
            text.contentsScale = 2
            layer?.addSublayer(text)
        }

        barsLayer.font = NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .medium)
        barsLayer.fontSize = 18
        barsLayer.alignmentMode = .left
        timeLayer.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        timeLayer.fontSize = 10
        timeLayer.foregroundColor = Theme.secondaryText.cgColor
        timeLayer.alignmentMode = .right
        tempoLayer.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        tempoLayer.fontSize = 10
        tempoLayer.foregroundColor = Theme.secondaryText.cgColor
        tempoLayer.alignmentMode = .right

        subscription = FrameClock.shared.subscribe { [weak self] in self?.update() }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        let subscription = subscription
        MainActor.assumeIsolated { FrameClock.shared.unsubscribe(subscription) }
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for text in [barsLayer, timeLayer, tempoLayer] { text.contentsScale = scale }
        barsLayer.frame = CGRect(x: 12, y: (bounds.height - 22) / 2, width: 130, height: 22)
        timeLayer.frame = CGRect(x: bounds.width - 110, y: bounds.height / 2, width: 100, height: 13)
        tempoLayer.frame = CGRect(x: bounds.width - 110, y: bounds.height / 2 - 14, width: 100, height: 13)
        CATransaction.commit()
    }

    private func update() {
        guard let app = rt.app() else { return }
        let rate = app.sampleRate()
        let tempo = app.tempo()
        let seconds = Double(app.position()) / rate

        // 4/4 only, as the engine is.
        let beats = seconds * tempo / 60
        let bar = Int(beats / 4) + 1
        let beat = Int(beats.truncatingRemainder(dividingBy: 4)) + 1
        let sixteenth = Int((beats * 4).truncatingRemainder(dividingBy: 4)) + 1
        setText(barsLayer, String(format: "%3d  %d  %d", bar, beat, sixteenth))

        let tenths = Int(seconds * 10)
        setText(timeLayer, String(format: "%02d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10))
        setText(tempoLayer, String(format: "%.0f bpm   4/4", tempo))
    }

    private func setText(_ layer: CATextLayer, _ text: String) {
        guard (layer.string as? String) != text else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.string = text
        CATransaction.commit()
    }
}

struct PositionDisplay: NSViewRepresentable {
    func makeNSView(context: Context) -> PositionDisplayNSView { PositionDisplayNSView() }
    func updateNSView(_ view: PositionDisplayNSView, context: Context) {}
}

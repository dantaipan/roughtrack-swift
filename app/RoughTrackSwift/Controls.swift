import AppKit
import SwiftUI

/// Fader travel to gain: a cube law, so most of the travel is where mixing happens. With
/// the usual top of +6 dB, 0 dB is about four fifths of the way up.
enum FaderLaw {
    static let maximumGain: Float = 2

    static func gain(at position: Double, maximum: Float = maximumGain) -> Float {
        maximum * Float(pow(min(max(position, 0), 1), 3))
    }

    static func position(for gain: Float, maximum: Float = maximumGain) -> Double {
        guard maximum > 0 else { return 0 }
        return pow(Double(max(gain, 0) / maximum), 1.0 / 3.0)
    }

    static func decibels(_ gain: Float) -> String {
        guard gain > 0.00001 else { return "-∞" }
        let value = 20 * log10(Double(gain))
        return String(format: abs(value) < 0.05 ? "0.0" : "%+.1f", value)
    }
}

/// Whether the press starting a drag is a double-click or an Option-click, either of
/// which puts a fader or knob back to its default. It's read from the drag itself, since
/// a drag that starts on the press leaves a double-tap gesture nothing to see.
@MainActor
func isResetClick() -> Bool {
    if NSEvent.modifierFlags.contains(.option) { return true }
    guard let event = NSApp.currentEvent, event.type == .leftMouseDown else { return false }
    return event.clickCount >= 2
}

/// A labelled line on a fader's scale.
struct FaderMark: Identifiable {
    let gain: Float
    let label: String
    var isMajor = false

    var id: String { label }

    /// For a fader up to +6 dB.
    static let decibels: [FaderMark] = [
        FaderMark(gain: 2, label: "+6"),
        FaderMark(gain: 1, label: "0", isMajor: true),
        FaderMark(gain: 0.5012, label: "-6"),
        FaderMark(gain: 0.2512, label: "-12"),
        FaderMark(gain: 0.0631, label: "-24"),
        FaderMark(gain: 0.00398, label: "-48"),
        FaderMark(gain: 0, label: "-∞"),
    ]

    /// For a level shown as a percentage of `maximum`.
    static func percent(of maximum: Float) -> [FaderMark] {
        [FaderMark(gain: maximum, label: "100", isMajor: true)] + [50, 25, 10, 0].map {
            FaderMark(gain: maximum * Float($0) / 100, label: "\($0)")
        }
    }
}

/// A flat vertical fader with its scale down the left. It holds its own value while being
/// dragged, so it doesn't wait for the model to catch up, and double-click or
/// Option-click puts it back to `resetGain`.
struct Fader: View {
    let gain: Float
    var maximum: Float = FaderLaw.maximumGain
    var marks: [FaderMark] = FaderMark.decibels
    var resetGain: Float = 1
    let onChange: (Float) -> Void

    /// Room for the scale's labels, and the width a fader with them needs.
    static let scaleWidth: CGFloat = 18
    static let width: CGFloat = 54

    @State private var dragPosition: Double?
    @State private var startPosition: Double = 0
    @State private var isResetting = false

    private let capHeight: CGFloat = 26

    var body: some View {
        GeometryReader { geometry in
            let travel = max(geometry.size.height - capHeight, 1)
            let position = dragPosition ?? FaderLaw.position(for: gain, maximum: maximum)
            let slotX = Self.scaleWidth + (geometry.size.width - Self.scaleWidth) / 2
            let markY = { (gain: Float) in
                (1 - FaderLaw.position(for: gain, maximum: maximum)) * travel + capHeight / 2
            }

            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Color(white: 0.08))
                    .frame(width: 4, height: travel)
                    .position(x: slotX, y: capHeight / 2 + travel / 2)

                ForEach(marks) { mark in
                    let y = markY(mark.gain)

                    Rectangle()
                        .fill(Color(Theme.secondaryText).opacity(mark.isMajor ? 0.7 : 0.4))
                        .frame(width: mark.isMajor ? 14 : 10, height: 1)
                        .position(x: slotX, y: y)

                    Text(mark.label)
                        .font(.system(size: 8, weight: mark.isMajor ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(Color(Theme.secondaryText).opacity(mark.isMajor ? 1 : 0.8))
                        .fixedSize()
                        .frame(width: Self.scaleWidth, alignment: .trailing)
                        .position(x: Self.scaleWidth / 2, y: y)
                }

                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(white: 0.78))
                    .overlay(Rectangle().fill(Color(white: 0.25)).frame(height: 1))
                    .frame(width: 26, height: capHeight)
                    .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
                    .position(x: slotX, y: (1 - position) * travel + capHeight / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if isResetting { return }
                        if dragPosition == nil {
                            if isResetClick() {
                                isResetting = true
                                reset()
                                return
                            }
                            startPosition = FaderLaw.position(for: gain, maximum: maximum)
                        }

                        // Hold Shift for fine moves.
                        let scale = NSEvent.modifierFlags.contains(.shift) ? 0.2 : 1.0
                        let moved = min(max(startPosition - Double(value.translation.height / travel) * scale, 0), 1)
                        dragPosition = moved
                        onChange(FaderLaw.gain(at: moved, maximum: maximum))
                    }
                    .onEnded { _ in
                        dragPosition = nil
                        isResetting = false
                    }
            )
        }
    }

    private func reset() {
        dragPosition = nil
        onChange(resetGain)
    }
}

/// A small flat knob. Drag up or down to turn it; double-click or Option-click puts it
/// back to its default. A bipolar knob, like pan, sticks briefly at its centre.
struct Knob: View {
    let value: Float
    let minimum: Float
    let maximum: Float
    let defaultValue: Float
    var size: CGFloat = 28
    var bipolar = false
    var tint: NSColor = Theme.text
    let onChange: (Float) -> Void

    @State private var dragValue: Float?
    @State private var startValue: Float = 0
    @State private var isResetting = false

    private var fraction: Double {
        guard maximum > minimum else { return 0 }
        return Double(((dragValue ?? value) - minimum) / (maximum - minimum))
    }

    var body: some View {
        let start = Angle.degrees(135)
        let sweep = 270.0
        let pointer = Angle.degrees(135 + sweep * fraction)
        let from = bipolar ? Angle.degrees(270) : start

        ZStack {
            Circle().fill(Color(white: 0.26))
            Circle().stroke(Color(white: 0.12), lineWidth: 1)

            // The arc from the start (or the centre, for a pan knob) to the value
            Path { path in
                let radius = size / 2 - 2
                let centre = CGPoint(x: size / 2, y: size / 2)
                let lower = min(from.degrees, pointer.degrees)
                let upper = max(from.degrees, pointer.degrees)
                path.addArc(center: centre, radius: radius, startAngle: .degrees(lower), endAngle: .degrees(upper), clockwise: false)
            }
            .stroke(Color(tint), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

            Rectangle()
                .fill(Color(Theme.text))
                .frame(width: 2, height: size / 2 - 6)
                .offset(y: -(size / 4 - 1))
                .rotationEffect(pointer + .degrees(90))
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if isResetting { return }
                    if dragValue == nil {
                        if isResetClick() {
                            isResetting = true
                            onChange(defaultValue)
                            return
                        }
                        startValue = value
                    }
                    let scale: Float = NSEvent.modifierFlags.contains(.shift) ? 600 : 150
                    let moved = startValue - Float(drag.translation.height) / scale * (maximum - minimum)
                    var clamped = min(max(moved, minimum), maximum)
                    // A few points of travel either side of the centre land on it exactly.
                    if bipolar, abs(clamped - defaultValue) < (maximum - minimum) * 0.04 {
                        clamped = defaultValue
                    }
                    dragValue = clamped
                    onChange(clamped)
                }
                .onEnded { _ in
                    dragValue = nil
                    isResetting = false
                }
        )
    }
}

/// A knob or an on/off switch for one of the engine's parameters, labelled with its name
/// and value.
struct ParameterControl: View {
    let parameter: StudioModel.Parameter
    let value: Float
    let onChange: (Float) -> Void

    var body: some View {
        VStack(spacing: 4) {
            if parameter.isSwitch {
                Button {
                    onChange(value > 0.5 ? 0 : 1)
                } label: {
                    Text(value > 0.5 ? "On" : "Off")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(value > 0.5 ? Color.black.opacity(0.85) : Color(Theme.secondaryText))
                        .frame(width: 44, height: 22)
                        .background(RoundedRectangle(cornerRadius: 4).fill(value > 0.5 ? Color(Theme.play) : Color(white: 0.28)))
                }
                .buttonStyle(.plain)
            } else {
                Knob(value: value, minimum: parameter.minimum, maximum: parameter.maximum,
                     defaultValue: parameter.defaultValue, size: 34, bipolar: parameter.minimum < 0 && parameter.maximum > 0,
                     tint: Theme.mute, onChange: onChange)
            }

            Text(parameter.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color(Theme.text))
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if !parameter.isSwitch {
                Text(formatted)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Color(Theme.secondaryText))
                    .lineLimit(1)
            }
        }
        .frame(width: 70)
    }

    private var formatted: String {
        let range = parameter.maximum - parameter.minimum
        let digits = range >= 100 ? 0 : (range >= 10 ? 1 : 2)
        let number = String(format: "%.\(digits)f", value)
        return parameter.suffix.isEmpty ? number : "\(number) \(parameter.suffix.trimmingCharacters(in: .whitespaces))"
    }
}

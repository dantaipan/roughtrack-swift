import AppKit
import SwiftUI

/// Fader travel to gain: a cube law up to +6 dB, so most of the travel is where
/// mixing happens, with 0 dB about four fifths of the way up.
enum FaderLaw {
    static let maximumGain: Float = 2

    static func gain(at position: Double) -> Float {
        maximumGain * Float(pow(min(max(position, 0), 1), 3))
    }

    static func position(for gain: Float) -> Double {
        pow(Double(max(gain, 0) / maximumGain), 1.0 / 3.0)
    }

    static func decibels(_ gain: Float) -> String {
        guard gain > 0.00001 else { return "-∞" }
        let value = 20 * log10(Double(gain))
        return String(format: abs(value) < 0.05 ? "0.0" : "%+.1f", value)
    }
}

/// A flat vertical fader. It holds its own value while being dragged, so it doesn't wait
/// for the model to catch up, and double-click or Option-click puts it back to 0 dB.
struct Fader: View {
    let gain: Float
    let onChange: (Float) -> Void

    @State private var dragPosition: Double?
    @State private var startPosition: Double = 0

    private let capHeight: CGFloat = 26

    var body: some View {
        GeometryReader { geometry in
            let travel = max(geometry.size.height - capHeight, 1)
            let position = dragPosition ?? FaderLaw.position(for: gain)
            let capY = (1 - position) * travel

            ZStack(alignment: .top) {
                // The slot, and a mark at 0 dB
                Capsule()
                    .fill(Color(white: 0.08))
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
                    .padding(.vertical, capHeight / 2)

                Rectangle()
                    .fill(Color(Theme.secondaryText).opacity(0.6))
                    .frame(width: 14, height: 1)
                    .offset(y: (1 - FaderLaw.position(for: 1)) * travel + capHeight / 2)

                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(white: 0.78))
                    .overlay(Rectangle().fill(Color(white: 0.25)).frame(height: 1))
                    .frame(width: 26, height: capHeight)
                    .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
                    .offset(y: capY)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragPosition == nil {
                            if NSEvent.modifierFlags.contains(.option) {
                                reset()
                                return
                            }
                            startPosition = FaderLaw.position(for: gain)
                        }

                        // Hold Shift for fine moves.
                        let scale = NSEvent.modifierFlags.contains(.shift) ? 0.2 : 1.0
                        let moved = min(max(startPosition - Double(value.translation.height / travel) * scale, 0), 1)
                        dragPosition = moved
                        onChange(FaderLaw.gain(at: moved))
                    }
                    .onEnded { _ in dragPosition = nil }
            )
            .onTapGesture(count: 2, perform: reset)
        }
    }

    private func reset() {
        dragPosition = nil
        onChange(1)
    }
}

/// A small flat knob. Drag up or down to turn it; double-click puts it back to its default.
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
                    if dragValue == nil { startValue = value }
                    let scale: Float = NSEvent.modifierFlags.contains(.shift) ? 600 : 150
                    let moved = startValue - Float(drag.translation.height) / scale * (maximum - minimum)
                    let clamped = min(max(moved, minimum), maximum)
                    dragValue = clamped
                    onChange(clamped)
                }
                .onEnded { _ in dragValue = nil }
        )
        .onTapGesture(count: 2) {
            dragValue = nil
            onChange(defaultValue)
        }
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

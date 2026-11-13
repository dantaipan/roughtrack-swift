import AppKit
import RoughTrackCore
import SwiftUI

/// The app's flat look: neutral greys, the system font, and colour kept for what
/// the colour means (track kinds, mute, solo, record).
enum Theme {
    // Surfaces, darkest first
    static let window = NSColor(white: 0.13, alpha: 1)
    static let lanes = NSColor(white: 0.17, alpha: 1)
    static let laneAlternate = NSColor(white: 0.155, alpha: 1)
    static let header = NSColor(white: 0.20, alpha: 1)
    static let headerSelected = NSColor(white: 0.25, alpha: 1)
    static let separator = NSColor(white: 0.08, alpha: 1)
    static let ruler = NSColor(white: 0.22, alpha: 1)
    static let display = NSColor(white: 0.08, alpha: 1)
    static let scrollerKnob = NSColor(white: 0.40, alpha: 1)

    // Text
    static let text = NSColor(white: 0.90, alpha: 1)
    static let secondaryText = NSColor(white: 0.60, alpha: 1)
    static let displayText = NSColor(white: 0.92, alpha: 1)

    // Meaning
    static let playhead = NSColor(white: 0.95, alpha: 1)
    static let mute = NSColor(red: 0.30, green: 0.60, blue: 0.95, alpha: 1)
    static let solo = NSColor(red: 0.96, green: 0.78, blue: 0.20, alpha: 1)
    static let record = NSColor(red: 0.92, green: 0.26, blue: 0.24, alpha: 1)
    static let monitor = NSColor(red: 0.95, green: 0.55, blue: 0.20, alpha: 1)
    static let cycle = NSColor(red: 0.85, green: 0.72, blue: 0.30, alpha: 1)
    /// The reverb and delay: their returns and every track's sends to them. Violet, so
    /// they don't read as a track kind or the loop.
    static let effectReturn = NSColor(red: 0.62, green: 0.52, blue: 0.90, alpha: 1)
    static let selection = NSColor(white: 1.0, alpha: 0.9)
    static let play = NSColor(red: 0.35, green: 0.80, blue: 0.40, alpha: 1)
    static let meterLow = NSColor(red: 0.30, green: 0.80, blue: 0.40, alpha: 1)
    static let meterHigh = NSColor(red: 0.95, green: 0.75, blue: 0.20, alpha: 1)
    static let drumFill = NSColor(red: 0.90, green: 0.48, blue: 0.25, alpha: 1)
    static let meterClip = NSColor(red: 0.92, green: 0.26, blue: 0.24, alpha: 1)

    /// Each kind of track has its own colour, as its regions do.
    static func colour(for kind: rt.TrackKind) -> NSColor {
        switch kind {
        case .midi: return NSColor(red: 0.36, green: 0.72, blue: 0.40, alpha: 1)
        case .drums: return NSColor(red: 0.90, green: 0.70, blue: 0.25, alpha: 1)
        default: return NSColor(red: 0.30, green: 0.58, blue: 0.86, alpha: 1)
        }
    }

    static let laneHeight: CGFloat = 64
    static let headerWidth: CGFloat = 230
    static let rulerHeight: CGFloat = 26
}

extension Color {
    init(_ colour: NSColor) {
        self.init(nsColor: colour)
    }
}

/// Converts a level to a 0 to 1 meter reading over a 60 dB range.
func meterFraction(_ level: Float) -> CGFloat {
    let decibels = 20 * log10(max(Double(level), 1e-6))
    return CGFloat(min(max((decibels + 60) / 60, 0), 1))
}

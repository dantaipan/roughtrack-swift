import AppKit
import SwiftUI

/// RoughTrack's About box, with the same credits the JUCE app shows.
struct AboutView: View {
    @EnvironmentObject private var model: StudioModel

    static let credits = """
    Drums
    DRSKit by Lars Muldjord and Bent Bisballe Nyeng, recorded on a kit by Jes Eiler of DRSDrums. \
    Drum samples provided by DrumGizmo.org, under Creative Commons Attribution 4.0 \
    (creativecommons.org/licenses/by/4.0). Mixed to stereo for RoughTrack: each drum's close, overhead \
    and room microphones were combined, a subset of hits was kept, each hit was trimmed and faded, \
    levels were set, and the audio was converted to 48 kHz.

    Grooves
    Groove MIDI Dataset by Jon Gillick, Adam Roberts, Peter Rob and David Bansal, Google Magenta, under \
    Creative Commons Attribution 4.0. Performances were aligned to their bars, steady sections and fills \
    were selected, and notes were reduced to thirteen drum sounds.

    Software
    JUCE, under the GNU AGPL 3.0
    NeuralAmpModelerCore, MIT
    Eigen, MPL 2.0
    nlohmann/json, MIT
    """

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("RoughTrack")
                .font(.system(size: 22, weight: .semibold))
            Text("Version \(model.version)")
                .font(.callout)
                .foregroundStyle(Color(Theme.secondaryText))
            Text("A simplified multitrack DAW for macOS.")
                .font(.callout)
                .padding(.top, 4)

            ScrollView {
                Text(Self.credits)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(Theme.text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 180)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(Theme.header)))
            .padding(.top, 8)

            Text("© 2026 Dan Mullins. Free software under the GNU AGPL 3.0 or later.")
                .font(.system(size: 10))
                .foregroundStyle(Color(Theme.secondaryText))
                .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 440)
        .background(Color(Theme.window))
    }
}

/// Shown while a mixdown or stem export runs; nothing else can happen meanwhile.
struct MixdownSheet: View {
    @EnvironmentObject private var model: StudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mixing Down…").font(.headline)
            ProgressView(value: model.mixdownProgress)
                .frame(width: 320)
            HStack {
                Spacer()
                Button("Cancel") { model.cancelMixdown() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .interactiveDismissDisabled()
    }
}

/// Says a newer RoughTrack is out, with its notes, or that this one is current.
struct UpdateSheet: View {
    let update: StudioModel.Update
    @EnvironmentObject private var model: StudioModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if update.hasRelease {
                Text("RoughTrack \(update.version) is available").font(.headline)
                Text("You have \(model.version).")
                    .foregroundStyle(Color(Theme.secondaryText))
                ScrollView {
                    Text(update.notes)
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(width: 420, height: 220)

                HStack {
                    Button("Skip This Version") {
                        model.skipUpdate(update.version)
                        dismiss()
                    }
                    Spacer()
                    Button("Later") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Download") {
                        if let url = update.downloadURL { NSWorkspace.shared.open(url) }
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                Text(update.error.isEmpty ? "RoughTrack is up to date" : "Couldn't Check for Updates").font(.headline)
                Text(update.error.isEmpty ? "Version \(model.version) is the newest." : update.error)
                HStack {
                    Spacer()
                    Button("OK") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }
}

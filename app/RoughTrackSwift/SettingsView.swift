import CxxStdlib
import RoughTrackCore
import SwiftUI

/// Audio device, sample rate and buffer size, latency calibration, and which MIDI port
/// is the keyboard's DAW controls.
struct SettingsView: View {
    @EnvironmentObject private var model: StudioModel
    @State private var confirmingCalibration = false

    @State private var devices: [String] = []
    @State private var rates: [Double] = []
    @State private var bufferSizes: [Int] = []
    @State private var device = ""
    @State private var rate: Double = 48000
    @State private var bufferSize = 64
    @State private var error: String?

    var body: some View {
        Form {
            Picker("Audio device", selection: $device) {
                ForEach(devices, id: \.self) { Text($0).tag($0) }
            }

            Picker("Sample rate", selection: $rate) {
                ForEach(rates, id: \.self) { Text(String(format: "%.1f kHz", $0 / 1000)).tag($0) }
            }

            Picker("Buffer size", selection: $bufferSize) {
                ForEach(bufferSizes, id: \.self) { size in
                    Text("\(size) samples (\(String(format: "%.1f", Double(size) / rate * 1000)) ms)").tag(size)
                }
            }

            if let error {
                Text(error).foregroundStyle(Color(Theme.monitor))
            }

            HStack {
                Spacer()
                Button("Apply", action: apply)
                    .keyboardShortcut(.defaultAction)
            }

            Section("Recording latency") {
                HStack {
                    Text(model.calibratedLatencyMs < 0
                         ? "Not calibrated for this device and buffer size."
                         : String(format: "Round trip: %.2f ms", model.calibratedLatencyMs))
                        .foregroundStyle(Color(Theme.secondaryText))
                    Spacer()
                    if model.calibrating {
                        ProgressView().controlSize(.small)
                        Text("Measuring…")
                    } else {
                        Button("Calibrate Latency…") { confirmingCalibration = true }
                    }
                }
            }

            Section("Keyboard controls") {
                Picker("DAW control port", selection: Binding(
                    get: { model.controllerAutomatic ? Self.automatic : model.controllerName },
                    set: { model.chooseController($0 == Self.automatic ? nil : $0) })) {
                    Text("Automatic").tag(Self.automatic)
                    Text("None").tag("")
                    Divider()
                    ForEach(model.midiInputNames, id: \.self) { Text($0).tag($0) }
                }

                Text(model.controllerName.isEmpty
                     ? "No port in use. Transport messages (MMC) from any keyboard still work."
                     : "Using \(model.controllerName): its fader buttons cover tracks \(model.controllerBank + 1)–\(model.controllerBank + 8).")
                    .font(.callout)
                    .foregroundStyle(Color(Theme.secondaryText))
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .onAppear(perform: load)
        .alert("Calibrate Latency", isPresented: $confirmingCalibration) {
            Button("Start") { model.startCalibration() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Connect Output 1 to Input 1 with a cable and turn your monitors and headphones down. RoughTrack will play three short test sweeps.")
        }
        .alert(model.calibrationMessage?.title ?? "",
               isPresented: Binding(get: { model.calibrationMessage != nil }, set: { if !$0 { model.calibrationMessage = nil } })) {
            Button("OK") { model.calibrationMessage = nil }
        } message: {
            Text(model.calibrationMessage?.text ?? "")
        }
    }

    private static let automatic = "\u{1}automatic"

    private func load() {
        guard let app = rt.app() else { return }
        let info = app.audioDevice()
        devices = info.devices.map { String($0) }
        rates = info.sampleRates.map { $0 }
        bufferSizes = info.bufferSizes.map { Int($0) }
        device = String(info.name)
        rate = info.sampleRate
        bufferSize = Int(info.bufferSize)
    }

    private func apply() {
        guard let app = rt.app() else { return }
        let problem = String(app.chooseAudioDevice(std.string(device), rate, Int32(bufferSize)))
        error = problem.isEmpty ? nil : problem
        load()
    }
}

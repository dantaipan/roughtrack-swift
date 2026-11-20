import RoughTrackCore
import SwiftUI

/// The mixer, docked under the tracks or in its own window: a strip per track, the reverb
/// and delay returns, and the master. Each strip takes plain values rather than watching
/// the model, so moving one fader redraws only that strip.
struct MixerView: View {
    /// In its own window, rather than under the tracks.
    let undocked: Bool
    @EnvironmentObject private var model: StudioModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 1) {
                ForEach(model.tracks) { track in
                    ChannelStripView(track: track, inserts: model.inserts[track.id] ?? [],
                                     effects: model.effects, instruments: model.instruments,
                                     inputChannelCount: model.inputChannelCount,
                                     isSelected: model.selectedTrack == track.id, model: model)
                }

                Spacer(minLength: 12)

                ReturnStrip(name: "Reverb", returnIndex: StudioModel.reverbReturnIndex, editIndexes: [0, 1, 2], model: model,
                            level: aux(StudioModel.reverbReturnIndex))
                ReturnStrip(name: "Delay", returnIndex: StudioModel.delayReturnIndex, editIndexes: [3, 4, 5, 6], model: model,
                            level: aux(StudioModel.delayReturnIndex))
                MasterStrip(gain: model.masterGain, model: model)
                DockColumn(undocked: undocked, model: model)
            }
            .padding(.horizontal, 1)
            .frame(maxHeight: .infinity)
        }
        .background(Color(Theme.separator))
    }

    private func aux(_ index: Int) -> Float {
        index < model.auxValues.count ? model.auxValues[index] : 0
    }
}

/// The undocked mixer's window. Closing it hides the mixer, as X does, and the mixer
/// opens here again next time.
struct MixerWindow: View {
    @EnvironmentObject private var model: StudioModel

    var body: some View {
        MixerView(undocked: true)
            .frame(minWidth: 500, minHeight: 420)
            .navigationTitle("Mixer")
            .onDisappear {
                if model.mixerUndocked && !StudioModel.quitting { model.showingMixer = false }
            }
    }
}

/// Beside the master: moves the mixer between the main window and its own.
private struct DockColumn: View {
    let undocked: Bool
    let model: StudioModel

    var body: some View {
        VStack {
            Button { model.toggleMixerDocking() } label: {
                Image(systemName: undocked ? "rectangle.bottomhalf.inset.filled" : "macwindow.badge.plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(Theme.secondaryText))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help(undocked ? "Put the Mixer Back in the Main Window (⌥⌘X)" : "Open the Mixer in Its Own Window (⌥⌘X)")
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .frame(width: 24)
        .frame(maxHeight: .infinity)
        .background(Color(Theme.header))
    }
}

private enum StripLayout {
    static let width: CGFloat = 92
    static let slotHeight: CGFloat = 19
}

private struct StripBackground: ViewModifier {
    var isSelected = false

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 6)
            .frame(width: StripLayout.width)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(isSelected ? Theme.headerSelected : Theme.header))
    }
}

// MARK: - Channel strip

private struct ChannelStripView: View {
    let track: StudioModel.Track
    let inserts: [StudioModel.Insert]
    let effects: [StudioModel.Plugin]
    let instruments: [StudioModel.Plugin]
    let inputChannelCount: Int
    let isSelected: Bool
    let model: StudioModel

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 5) {
            if track.kind == .audio {
                inputMenu
            } else {
                Text(track.kind == .midi ? "MIDI" : "Drums")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(Theme.secondaryText))
                    .frame(height: StripLayout.slotHeight)
            }

            Button {
                openWindow(id: "channel", value: track.id)
            } label: {
                SlotLabel(text: track.ampName.isEmpty ? "Channel" : track.ampName,
                          isEmpty: track.ampName.isEmpty, systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.plain)
            .help("Amp, cabinet, EQ, compressor and sends")

            VStack(spacing: 2) {
                ForEach(inserts) { insert in
                    InsertSlot(track: track.id, insert: insert,
                               plugins: insert.isInstrumentSlot ? instruments : effects, model: model)
                }
            }

            HStack(spacing: 10) {
                sendKnob(index: StudioModel.sendReverbIndex, value: track.sendReverb, label: "Rev")
                sendKnob(index: StudioModel.sendDelayIndex, value: track.sendDelay, label: "Dly")
            }

            VStack(spacing: 1) {
                Knob(value: track.pan, minimum: -1, maximum: 1, defaultValue: 0, size: 28, bipolar: true, tint: Theme.mute) {
                    model.setPan(track.id, $0)
                }
                Text("Pan \(panLabel(track.pan))")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(Color(Theme.secondaryText))
            }
            .help("Pan: where the track sits between left and right. Double-click or Option-click to centre it.")

            HStack(alignment: .top, spacing: 4) {
                Fader(gain: track.gain) { model.setGain(track.id, $0) }
                    .frame(width: Fader.width)
                LevelMeter(track: track.id)
                    .frame(width: 6)
            }
            .frame(maxHeight: .infinity)

            Text(FaderLaw.decibels(track.gain))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Color(Theme.secondaryText))

            HStack(spacing: 3) {
                StripToggle(label: "M", isOn: track.muted, colour: Theme.mute) { model.setMuted(track, !track.muted) }
                StripToggle(label: "S", isOn: track.soloed, colour: Theme.solo) { model.setSoloed(track, !track.soloed) }
                StripToggle(label: "R", isOn: track.armed, colour: Theme.record) { model.setArmed(track, !track.armed) }
            }

            HStack(spacing: 3) {
                if track.kind == .audio {
                    StripToggle(label: "I", isOn: track.monitoring, colour: Theme.monitor) { model.setMonitoring(track, !track.monitoring) }
                }
                StripToggle(label: "Ø", isOn: track.inverted, colour: Theme.solo) { model.setInverted(track, !track.inverted) }
                    .help("Invert polarity")
            }

            Text(track.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.85))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(Color(Theme.colour(for: track.kind)))
        }
        .padding(.horizontal, 5)
        .modifier(StripBackground(isSelected: isSelected))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedTrack = track.id }
    }

    private var inputMenu: some View {
        let stereo = track.inputChannels == 2
        let label = stereo ? "St \(track.firstInput + 1)-\(track.firstInput + 2)" : "In \(track.firstInput + 1)"

        return Menu {
            ForEach(0..<max(inputChannelCount, 1), id: \.self) { channel in
                Button("In \(channel + 1)") { model.setInput(track, first: channel, channels: 1) }
            }
            if inputChannelCount >= 2 {
                Divider()
                Button("St 1-2") { model.setInput(track, first: 0, channels: 2) }
            }
        } label: {
            HStack(spacing: 2) {
                Text(label)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color(Theme.text))
            .frame(maxWidth: .infinity, minHeight: StripLayout.slotHeight)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.16)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Input")
    }

    /// C at the centre, otherwise L or R and how far, up to 100.
    private func panLabel(_ pan: Float) -> String {
        let amount = Int((abs(pan) * 100).rounded())
        return amount == 0 ? "C" : "\(pan < 0 ? "L" : "R")\(amount)"
    }

    private func sendKnob(index: Int32, value: Float, label: String) -> some View {
        let parameter = model.channelParameters.first { $0.index == Int(index) }

        return VStack(spacing: 1) {
            Knob(value: value, minimum: parameter?.minimum ?? 0,
                 maximum: parameter?.maximum ?? 1, defaultValue: parameter?.defaultValue ?? 0,
                 size: 22, tint: Theme.effectReturn) {
                model.setChannelParameter(track.id, Int(index), $0)
            }
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Color(Theme.secondaryText))
        }
        .help(parameter?.label ?? label)
    }
}

/// A slot showing a plugin's name, or a dash when it's empty.
private struct SlotLabel: View {
    let text: String
    var isEmpty = false
    var isBypassed = false
    var beforeAmp = false
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if beforeAmp {
                Text("◂")
                    .font(.system(size: 9))
                    .help("Before the amp")
            }
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9))
            }
            Text(isEmpty && systemImage == nil ? "–" : text)
                .font(.system(size: 10, weight: isEmpty ? .regular : .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(isEmpty ? Color(Theme.secondaryText) : (isBypassed ? Color(Theme.secondaryText) : Color(Theme.text)))
        .frame(maxWidth: .infinity, minHeight: StripLayout.slotHeight)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 3).fill(isEmpty ? Color(white: 0.16) : Color(white: isBypassed ? 0.22 : 0.30)))
        .overlay(alignment: .leading) {
            if !isEmpty && !isBypassed {
                RoundedRectangle(cornerRadius: 1).fill(Color(Theme.play)).frame(width: 2).padding(.vertical, 3)
            }
        }
    }
}

/// One plugin slot. Click a filled slot to open its editor; the menu holds the rest.
private struct InsertSlot: View {
    let track: Int
    let insert: StudioModel.Insert
    let plugins: [StudioModel.Plugin]
    let model: StudioModel

    var body: some View {
        if insert.isEmpty {
            Menu {
                pluginChoices
            } label: {
                SlotLabel(text: insert.isInstrumentSlot ? "Instrument" : "–", isEmpty: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help(insert.isInstrumentSlot ? "Choose an instrument" : "Add a plugin")
        } else {
            Menu {
                filledSlotItems
            } label: {
                SlotLabel(text: insert.name, isBypassed: insert.bypassed, beforeAmp: insert.beforeAmp)
            } primaryAction: {
                model.openPluginWindow(track, slot: insert.slot)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("\(insert.name) (\(insert.format)). Click to open, right-click for more.")
            .contextMenu { filledSlotItems }
        }
    }

    @ViewBuilder private var filledSlotItems: some View {
        Button("Open") { model.openPluginWindow(track, slot: insert.slot) }
        Toggle("Bypass", isOn: Binding(get: { insert.bypassed }, set: { model.setBypassed(track, slot: insert.slot, $0) }))
        if !insert.isInstrumentSlot {
            Toggle("Before Amp", isOn: Binding(get: { insert.beforeAmp }, set: { model.setBeforeAmp(track, slot: insert.slot, $0) }))
        }
        Menu("Replace") { pluginChoices }
        Divider()
        Button("Remove") { model.removePlugin(track, slot: insert.slot) }
    }

    /// The scanned plugins grouped by maker, as RoughTrack lists them.
    @ViewBuilder private var pluginChoices: some View {
        let makers = Dictionary(grouping: plugins) { $0.maker.isEmpty ? "Unknown" : $0.maker }
        ForEach(makers.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }, id: \.self) { maker in
            Menu(maker) {
                ForEach(makers[maker] ?? []) { plugin in
                    Button("\(plugin.name) (\(plugin.format))") {
                        model.loadPlugin(track, slot: insert.slot, plugin: plugin)
                    }
                }
            }
        }
        if plugins.isEmpty {
            Text("No plugins found")
        }
        Divider()
        Button("Rescan Plugins") { model.rescanPlugins() }
    }
}

private struct StripToggle: View {
    let label: String
    let isOn: Bool
    let colour: NSColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isOn ? Color.black.opacity(0.85) : Color(Theme.secondaryText))
                .frame(width: 24, height: 18)
                .background(RoundedRectangle(cornerRadius: 3).fill(isOn ? Color(colour) : Color(white: 0.28)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Returns and master

/// A reverb or delay return: its level on a fader, and its settings in a popover.
private struct ReturnStrip: View {
    let name: String
    let returnIndex: Int
    let editIndexes: [Int]
    let model: StudioModel
    let level: Float

    @State private var showingSettings = false

    var body: some View {
        let parameter = model.auxParameters.first { $0.index == returnIndex }
        let maximum = parameter?.maximum ?? 1

        VStack(spacing: 6) {
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(Theme.text))

            Button("Edit…") { showingSettings = true }
                .controlSize(.small)
                .popover(isPresented: $showingSettings, arrowEdge: .trailing) {
                    EffectSettings(title: name, indexes: editIndexes, model: model)
                }

            // The return level runs over the parameter's own range, so 100% is the top.
            Fader(gain: level, maximum: maximum, marks: FaderMark.percent(of: maximum),
                  resetGain: parameter?.defaultValue ?? maximum) {
                model.setAuxParameter(returnIndex, min($0, maximum))
            }
            .frame(width: Fader.width)
            .frame(maxHeight: .infinity)

            Text(String(format: "%.0f%%", level / maximum * 100))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Color(Theme.secondaryText))

            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(Color(Theme.effectReturn))
        }
        .padding(.horizontal, 5)
        .modifier(StripBackground())
    }
}

private struct MasterStrip: View {
    let gain: Float
    let model: StudioModel

    var body: some View {
        VStack(spacing: 6) {
            Text("Stereo Out")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(Theme.text))

            HStack(alignment: .top, spacing: 4) {
                Fader(gain: gain) { model.setMasterGain($0) }
                    .frame(width: Fader.width)
                LevelMeter(track: -1)
                    .frame(width: 8)
            }
            .frame(maxHeight: .infinity)

            Text(FaderLaw.decibels(gain))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Color(Theme.secondaryText))

            Text("Master")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(Color(white: 0.75))
        }
        .padding(.horizontal, 5)
        .modifier(StripBackground())
    }
}

/// Reverb or delay settings, in a popover from its return strip.
struct EffectSettings: View {
    let title: String
    let indexes: [Int]
    let model: StudioModel

    @State private var values: [Int: Float] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            HStack(alignment: .top, spacing: 8) {
                ForEach(model.auxParameters.filter { indexes.contains($0.index) }) { parameter in
                    ParameterControl(parameter: parameter, value: values[parameter.index] ?? model.auxParameter(parameter.index)) {
                        values[parameter.index] = $0
                        model.setAuxParameter(parameter.index, $0)
                    }
                }
            }
        }
        .padding(16)
    }
}

import RoughTrackCore
import SwiftUI
import UniformTypeIdentifiers

/// A track's built-in channel: the amp capture and cabinet, EQ, compressor and sends.
/// Every control comes from the engine's own description of its parameters.
struct ChannelWindow: View {
    let track: Int
    @EnvironmentObject private var model: StudioModel

    /// Values being changed here, so knobs don't wait for the model.
    @State private var values: [Int: Float] = [:]
    @State private var message: String?
    @State private var browsing: Browsing?

    /// The TONE3000 browser, open for the capture or the cabinet.
    private struct Browsing: Identifiable {
        var target: rt.Tone3000Target
        var startingTone: Int?
        var id: String { "\(target == .amp ? "amp" : "cabinet")-\(startingTone ?? 0)" }
    }

    private enum Section: String, CaseIterable {
        case amp = "Amp", eq = "EQ", compressor = "Compressor", sends = "Sends"

        var parameters: [Int] {
            switch self {
            case .amp: return [0, 1]
            case .eq: return [2, 3, 4, 5, 6, 7]
            case .compressor: return [8, 9, 10, 11]
            case .sends: return [12, 13]
            }
        }
    }

    var body: some View {
        if let info = model.tracks.first(where: { $0.id == track }) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Rectangle().fill(Color(Theme.colour(for: info.kind))).frame(width: 4, height: 18)
                    Text(info.name).font(.title3.weight(.semibold))
                    Spacer()
                }

                fileRow(title: "Capture", name: info.ampName, source: info.ampTone3000, loading: info.ampLoading,
                        target: .amp, types: [UTType(filenameExtension: "nam") ?? .data, .wav],
                        load: { model.loadAmp(track, $0) }, clear: { model.removeAmp(track) })
                fileRow(title: "Cabinet IR", name: info.cabinetName, source: info.cabinetTone3000, loading: info.cabinetLoading,
                        target: .cabinet, types: [.wav, .aiff],
                        load: { model.loadCabinet(track, $0) }, clear: { model.clearCabinet(track) })

                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(Color(Theme.monitor))
                }

                ForEach(Section.allCases, id: \.self) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(Theme.secondaryText))
                        HStack(alignment: .top, spacing: 6) {
                            ForEach(model.channelParameters.filter { section.parameters.contains($0.index) }) { parameter in
                                ParameterControl(parameter: parameter, value: value(parameter.index)) {
                                    values[parameter.index] = $0
                                    model.setChannelParameter(track, parameter.index, $0)
                                }
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(Theme.header)))
                }
            }
            .padding(18)
            .frame(width: 520)
            .background(Color(Theme.window))
            .navigationTitle("\(info.name) Channel")
            .onChange(of: model.layoutRevision) { values.removeAll() }
            .sheet(item: $browsing) { browsing in
                Tone3000Browser(track: track, target: browsing.target, startingTone: browsing.startingTone,
                                tone3000: model.tone3000)
                    .environmentObject(model)
            }
        } else {
            Text("That track has gone.")
                .padding(40)
        }
    }

    private func value(_ index: Int) -> Float {
        values[index] ?? model.channelParameter(track, index)
    }

    private func fileRow(title: String, name: String, source: StudioModel.Tone3000Source?, loading: Bool,
                         target: rt.Tone3000Target, types: [UTType],
                         load: @escaping (URL) -> String?, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 80, alignment: .leading)

            Group {
                if loading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Downloading…").foregroundStyle(Color(Theme.secondaryText))
                    }
                } else if let source {
                    // From TONE3000: its mark and the tone's name; click to switch models.
                    Button {
                        browsing = Browsing(target: target, startingTone: source.toneId)
                    } label: {
                        HStack(spacing: 6) {
                            Image("t3k-logo")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 12)
                            Text(source.title)
                                .foregroundStyle(Color(Theme.text))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .buttonStyle(.plain)
                    .help([source.model, source.creator.isEmpty ? "" : "by \(source.creator)"]
                              .filter { !$0.isEmpty }.joined(separator: ", ") + ". Click to choose another model.")
                } else {
                    Text(name.isEmpty ? "None" : name)
                        .foregroundStyle(name.isEmpty ? Color(Theme.secondaryText) : Color(Theme.text))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.tone3000.account.available {
                Button("TONE3000…") { browsing = Browsing(target: target, startingTone: nil) }
                    .help(target == .amp ? "Choose a capture from TONE3000" : "Choose a cabinet IR from TONE3000")
            }
            Button("Load…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = types
                panel.directoryURL = model.ampFolder
                guard panel.runModal() == .OK, let url = panel.url else { return }
                message = load(url)
            }
            Button("Clear") {
                clear()
                message = nil
            }
            .disabled(name.isEmpty)
        }
    }
}

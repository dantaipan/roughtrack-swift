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

                fileRow(title: "Capture", name: info.ampName, types: [UTType(filenameExtension: "nam") ?? .data, .wav],
                        load: { model.loadAmp(track, $0) }, clear: { model.removeAmp(track) })
                fileRow(title: "Cabinet IR", name: info.cabinetName, types: [.wav, .aiff],
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
        } else {
            Text("That track has gone.")
                .padding(40)
        }
    }

    private func value(_ index: Int) -> Float {
        values[index] ?? model.channelParameter(track, index)
    }

    private func fileRow(title: String, name: String, types: [UTType],
                         load: @escaping (URL) -> String?, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 80, alignment: .leading)
            Text(name.isEmpty ? "None" : name)
                .font(.system(size: 12))
                .foregroundStyle(name.isEmpty ? Color(Theme.secondaryText) : Color(Theme.text))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
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

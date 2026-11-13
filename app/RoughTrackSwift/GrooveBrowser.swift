import AppKit
import SwiftUI

/// What a groove dragged from the browser carries: plain text, so the lanes (an NSView)
/// can read it without a custom pasteboard type.
enum GrooveDrag {
    static let prefix = "roughtrack-groove:"

    static func text(for id: String) -> String { prefix + id }

    static func grooveID(from text: String) -> String? {
        text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : nil
    }
}

/// The drum library beside the tracks, like Logic's loop browser: pick a style, hear a
/// groove through the drum track, then drag it onto a lane or double-click to add it at
/// the playhead.
struct GrooveBrowser: View {
    @EnvironmentObject private var model: StudioModel
    @AppStorage("grooveStyle") private var style = "Rock"
    @AppStorage("grooveFills") private var fills = false
    @State private var search = ""
    @FocusState private var searching: Bool

    private let columns = [GridItem(.adaptive(minimum: 78), spacing: 4)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Grooves")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    model.showingGrooves = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(Theme.secondaryText))
                .help("Hide Grooves")
            }
            .padding(.horizontal, 12)
            .frame(height: Theme.rulerHeight)
            .background(Color(Theme.ruler))

            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                    ForEach(model.grooveStyles, id: \.self) { name in
                        StyleButton(name: name, isOn: name == style && search.isEmpty) {
                            style = name
                            search = ""
                        }
                    }
                }

                Picker("", selection: $fills) {
                    Text("Beats").tag(false)
                    Text("Fills").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($searching)
            }
            .padding(10)

            Rectangle().fill(Color(Theme.separator)).frame(height: 1)

            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { groove in
                        GrooveRow(groove: groove, tempo: model.tempo,
                                  isPlaying: model.previewingGroove == groove.id,
                                  showStyle: !search.isEmpty)
                    }
                }
            }

            Rectangle().fill(Color(Theme.separator)).frame(height: 1)

            Text(model.drumTrack == nil
                 ? "Drag a groove onto the timeline to make a drum track. Grooves play through a drum track."
                 : "Drag onto a drum lane, or double-click to add at the playhead.")
                .font(.system(size: 10))
                .foregroundStyle(Color(Theme.secondaryText))
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
        }
        .frame(minWidth: 240, idealWidth: 280, maxWidth: 420)
        .background(Color(Theme.window))
        .onAppear { model.loadGrooves() }
        // Single-key shortcuts stay off while typing a search.
        .onChange(of: searching) { model.isEditingText = searching }
        .onDisappear { if searching { model.isEditingText = false } }
        .onChange(of: style) { model.stopGroovePreview() }
        .onChange(of: fills) { model.stopGroovePreview() }
    }

    private var shown: [StudioModel.Groove] {
        let text = search.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return model.grooves(style: style, fills: fills) }

        let matching = model.grooves.filter {
            $0.isFill == fills && ($0.name.localizedCaseInsensitiveContains(text) || $0.style.localizedCaseInsensitiveContains(text))
        }
        return matching.filter(\.nearTempo) + matching.filter { !$0.nearTempo }
    }
}

private struct StyleButton: View {
    let name: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(.system(size: 11, weight: isOn ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: 20)
                .foregroundStyle(isOn ? Color.black.opacity(0.85) : Color(Theme.text))
                .background(RoundedRectangle(cornerRadius: 4).fill(isOn ? Color(Theme.colour(for: .drums)) : Color(white: 0.24)))
        }
        .buttonStyle(.plain)
    }
}

private struct GrooveRow: View {
    let groove: StudioModel.Groove
    let tempo: Double
    let isPlaying: Bool
    let showStyle: Bool

    @EnvironmentObject private var model: StudioModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.toggleGroovePreview(groove)
            } label: {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 9))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(isPlaying ? Color.black.opacity(0.85) : Color(Theme.text))
                    .background(Circle().fill(isPlaying ? Color(Theme.colour(for: .drums)) : Color(white: 0.26)))
            }
            .buttonStyle(.plain)
            .help(isPlaying ? "Stop" : "Preview")

            VStack(alignment: .leading, spacing: 1) {
                Text(showStyle ? "\(groove.style) – \(groove.name)" : groove.name)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(groove.nearTempo ? Theme.text : Theme.secondaryText))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Color(Theme.secondaryText))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(isPlaying ? Color(Theme.colour(for: .drums)).opacity(0.15)
                              : (hovering ? Color.white.opacity(0.05) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.addPartAtPlayhead(groove) }
        .onDrag { NSItemProvider(object: GrooveDrag.text(for: groove.id) as NSString) }
        .help(groove.nearTempo ? "" : "Recorded at \(groove.recordedBpm) BPM, so it may sound less natural at \(Int(tempo.rounded())).")
    }

    // The names already say the tempo each was recorded at, so this is just the length.
    private var detail: String {
        groove.bars == 1 ? "1 bar" : "\(groove.bars) bars"
    }
}

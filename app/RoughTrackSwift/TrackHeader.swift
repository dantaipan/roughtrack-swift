import AppKit
import QuartzCore
import RoughTrackCore
import SwiftUI

/// A track's name and buttons, to the left of its lane. Click to select it, double-click
/// the name to rename it, drag it up or down to reorder, right-click to delete it.
struct TrackHeader: View {
    let track: StudioModel.Track
    let position: Int
    @EnvironmentObject private var model: StudioModel
    @State private var isRenaming = false
    @State private var newName = ""
    @State private var isDropTarget = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color(Theme.colour(for: track.kind)))
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(Theme.secondaryText))
                        .frame(width: 14)

                    if isRenaming {
                        TextField("Name", text: $newName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .focused($nameFocused)
                            .onSubmit(finishRenaming)
                            .onExitCommand(perform: cancelRenaming)
                            .onChange(of: nameFocused) { if !nameFocused { finishRenaming() } }
                    } else {
                        Text(track.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(Theme.text))
                            .lineLimit(1)
                            .onTapGesture(count: 2, perform: startRenaming)
                    }
                }

                HStack(spacing: 4) {
                    TrackToggle(label: "M", isOn: track.muted, colour: Theme.mute, help: "Mute") {
                        model.setMuted(track, !track.muted)
                    }
                    TrackToggle(label: "S", isOn: track.soloed, colour: Theme.solo, help: "Solo") {
                        model.setSoloed(track, !track.soloed)
                    }
                    TrackToggle(label: "R", isOn: track.armed, colour: Theme.record, help: "Record enable") {
                        model.setArmed(track, !track.armed)
                    }

                    // MIDI tracks always play what's played on the keyboard.
                    if track.kind == .audio {
                        TrackToggle(label: "I", isOn: track.monitoring, colour: Theme.monitor, help: "Input monitoring") {
                            model.setMonitoring(track, !track.monitoring)
                        }
                    }
                }
            }
            .padding(.leading, 8)

            Spacer(minLength: 4)

            LevelMeter(track: track.id)
                .frame(width: 6)
                .padding(.vertical, 8)
                .padding(.trailing, 8)
        }
        .frame(height: Theme.laneHeight)
        .background(Color(model.selectedTrack == track.id ? Theme.headerSelected : Theme.header))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(Theme.separator)).frame(height: 1)
        }
        .overlay(alignment: .top) {
            if isDropTarget {
                Rectangle().fill(Color(Theme.cycle)).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedTrack = track.id }
        .contextMenu {
            Button("Rename") { startRenaming() }
            Divider()
            Button("Delete Track…") { model.trackPendingDelete = track }
        }
        .draggable(String(track.id)) {
            Text(track.name)
                .font(.system(size: 12, weight: .medium))
                .padding(6)
                .background(Color(Theme.headerSelected))
        }
        .dropDestination(for: String.self) { items, _ in
            guard let moved = items.first.flatMap(Int.init), moved != track.id else { return false }
            model.moveTrack(moved, to: position)
            return true
        } isTargeted: { isDropTarget = $0 }
    }

    private var icon: String {
        switch track.kind {
        case .midi: return "pianokeys"
        case .drums: return "music.note"
        default: return "waveform"
        }
    }

    private func startRenaming() {
        newName = track.name
        isRenaming = true
        model.isEditingText = true
        DispatchQueue.main.async { nameFocused = true }
    }

    private func finishRenaming() {
        guard isRenaming else { return }
        isRenaming = false
        model.isEditingText = false
        if newName.trimmingCharacters(in: .whitespaces) != track.name {
            model.renameTrack(track, to: newName)
        }
    }

    private func cancelRenaming() {
        isRenaming = false
        model.isEditingText = false
    }
}

/// A small flat button that fills with its colour when on.
private struct TrackToggle: View {
    let label: String
    let isOn: Bool
    let colour: NSColor
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isOn ? Color.black.opacity(0.85) : Color(Theme.secondaryText))
                .frame(width: 22, height: 17)
                .background(RoundedRectangle(cornerRadius: 3).fill(isOn ? Color(colour) : Color(white: 0.28)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Meter

/// A thin vertical meter, a Core Animation layer moved by the frame clock.
final class LevelMeterNSView: NSView {
    var track: Int = -1
    private let fill = CALayer()
    private var subscription: UUID?
    private var lastHeight: CGFloat = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.10, alpha: 1).cgColor
        layer?.cornerRadius = 2
        layer?.masksToBounds = true
        fill.anchorPoint = .zero
        layer?.addSublayer(fill)
        subscription = FrameClock.shared.subscribe { [weak self] in self?.update() }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        let subscription = subscription
        MainActor.assumeIsolated { FrameClock.shared.unsubscribe(subscription) }
    }

    private func update() {
        guard let app = rt.app() else { return }
        let level = track >= 0 ? app.trackLevel(Int32(track)) : app.masterLevel()
        let fraction = meterFraction(level)
        let height = (fraction * bounds.height).rounded()

        // Most frames nothing moves, so nothing is sent to Core Animation.
        guard height != lastHeight else { return }
        lastHeight = height

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        fill.backgroundColor = (fraction > 0.95 ? Theme.meterClip : fraction > 0.8 ? Theme.meterHigh : Theme.meterLow).cgColor
        CATransaction.commit()
    }
}

/// The meter for a track, or the master if the track is -1.
struct LevelMeter: NSViewRepresentable {
    let track: Int

    func makeNSView(context: Context) -> LevelMeterNSView {
        let view = LevelMeterNSView()
        view.track = track
        return view
    }

    func updateNSView(_ view: LevelMeterNSView, context: Context) {
        view.track = track
    }
}

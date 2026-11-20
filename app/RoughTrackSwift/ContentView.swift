import SwiftUI

/// The main window: track headers beside their lanes under a ruler, with the transport
/// in the toolbar and a status line along the bottom.
struct ContentView: View {
    @EnvironmentObject private var model: StudioModel
    @State private var geometry = TimelineGeometry()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            if model.showingTuner {
                TunerStrip()
                    .frame(height: TunerNSView.height)
                Rectangle().fill(Color(Theme.separator)).frame(height: 1)
            }

            HStack(spacing: 0) {
                HStack {
                    Text("Tracks")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(Theme.secondaryText))
                    Spacer()
                    Menu {
                        Button("Audio Track") { model.addTrack(.audio) }
                        Button("MIDI Track") { model.addTrack(.midi) }
                        Button("Drum Track") { model.addTrack(.drums) }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("New Track")
                }
                .padding(.horizontal, 12)
                .frame(width: Theme.headerWidth, height: Theme.rulerHeight)
                .background(Color(Theme.ruler))

                Rectangle().fill(Color(Theme.separator)).frame(width: 1)

                RulerView(geometry: geometry)
            }
            .frame(height: Theme.rulerHeight)

            Rectangle().fill(Color(Theme.separator)).frame(height: 1)

            HSplitView {
            VSplitView {
                VStack(spacing: 0) {
                // The lanes fill the window, with a lane's worth to spare, so files can be
                // dropped below the last track to make a new one.
                GeometryReader { viewport in
                    ScrollView(.vertical) {
                        HStack(alignment: .top, spacing: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(model.tracks.enumerated()), id: \.element.id) { position, track in
                                    TrackHeader(track: track, position: position)
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(width: Theme.headerWidth)
                            .background(Color(Theme.window))

                            Rectangle().fill(Color(Theme.separator)).frame(width: 1)

                            LanesView(geometry: geometry)
                        }
                        .frame(height: max(CGFloat(model.tracks.count + 1) * Theme.laneHeight, viewport.size.height))
                    }
                }

                Rectangle().fill(Color(Theme.separator)).frame(height: 1)

                HStack(spacing: 0) {
                    Color(Theme.ruler).frame(width: Theme.headerWidth)
                    Rectangle().fill(Color(Theme.separator)).frame(width: 1)
                    TimelineScroller(geometry: geometry)
                }
                .frame(height: TimelineScrollerNSView.height)
                }
                .background(Color(Theme.window))
                .frame(minHeight: 120)

                if model.showingMixer && !model.mixerUndocked {
                    MixerView(undocked: false)
                        .frame(minHeight: 420)
                }
            }
            .frame(minWidth: 500)

                if model.showingGrooves {
                    GrooveBrowser()
                }
            }

            StatusBar()
        }
        .background(Color(Theme.window))
        .background(IconOnlyToolbar())
        .navigationTitle(model.sessionName.isEmpty ? "RoughTrack" : model.sessionName)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ControlBar()
            }
        }
        .sheet(isPresented: $model.showingNewSession) {
            NewSessionSheet()
        }
        .sheet(isPresented: Binding(get: { model.mixingDown }, set: { _ in })) {
            MixdownSheet()
        }
        .sheet(item: $model.update) { update in
            UpdateSheet(update: update)
        }
        .alert(model.mixdownResult?.title ?? "",
               isPresented: Binding(get: { model.mixdownResult != nil }, set: { if !$0 { model.mixdownResult = nil } })) {
            if let result = model.mixdownResult, result.succeeded {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: result.path)])
                    model.mixdownResult = nil
                }
            }
            Button("OK") { model.mixdownResult = nil }
        } message: {
            Text(model.mixdownResult?.text ?? "")
        }
        .alert("Can't Record",
               isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .alert("Delete \(model.trackPendingDelete?.name ?? "Track")?",
               isPresented: Binding(get: { model.trackPendingDelete != nil }, set: { if !$0 { model.trackPendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let track = model.trackPendingDelete { model.deleteTrack(track) }
                model.trackPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { model.trackPendingDelete = nil }
        } message: {
            Text("Its clips and plugins go, and undo history is cleared. Its recordings stay in the session folder, so Add Take at Playhead can bring them back.")
        }
        .task {
            if let request = SnapshotRequest.current {
                await Snapshot.run(request, model: model, openWindow: openWindow)
            }
        }
        .onChange(of: model.layoutRevision) {
            geometry.sampleRate = model.sampleRate
            geometry.tempo = model.tempo
            geometry.timingChanged()
        }
        // The undocked mixer's window follows the model, including at launch, when macOS
        // may have restored it whatever the saved setting says.
        .onAppear { showMixerWindow(mixerWindowWanted) }
        .onChange(of: mixerWindowWanted) { showMixerWindow(mixerWindowWanted) }
    }

    private var mixerWindowWanted: Bool { model.showingMixer && model.mixerUndocked }

    private func showMixerWindow(_ show: Bool) {
        if show { openWindow(id: "mixer") } else { dismissWindow(id: "mixer") }
    }
}

private struct StatusBar: View {
    @EnvironmentObject private var model: StudioModel

    var body: some View {
        HStack(spacing: 8) {
            if model.restoringPlugins {
                ProgressView().controlSize(.mini)
                Text("Loading plugins…")
                    .foregroundStyle(Color(Theme.secondaryText))
            }

            Text(model.statusText)
                .foregroundStyle(model.statusIsWarning ? Color(Theme.monitor) : Color(Theme.secondaryText))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Color(Theme.ruler))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(Theme.separator)).frame(height: 1)
        }
    }
}

private struct NewSessionSheet: View {
    @EnvironmentObject private var model: StudioModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Session").font(.headline)

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(create)

            if let error {
                Text(error).font(.callout).foregroundStyle(Color(Theme.monitor))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func create() {
        if let problem = model.newSession(name) {
            error = problem
        } else {
            dismiss()
        }
    }
}

/// Keeps the main window's toolbar to icons only. The transport is one toolbar item
/// with no label, so "Icon and Text" in the toolbar's menu only added an empty strip.
private struct IconOnlyToolbar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowWatcher() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class WindowWatcher: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // SwiftUI adds the toolbar after the content, so wait a turn for it.
            DispatchQueue.main.async { [weak self] in
                guard let toolbar = self?.window?.toolbar else { return }
                toolbar.displayMode = .iconOnly
                if #available(macOS 15.0, *) {
                    toolbar.allowsDisplayModeCustomization = false
                }
            }
        }
    }
}

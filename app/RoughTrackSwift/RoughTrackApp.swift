import RoughTrackCore
import SwiftUI

struct RoughTrackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: StudioModel

    init() {
        // JUCE and the studio start before any view asks for them.
        rt.startStudio()
        _model = StateObject(wrappedValue: StudioModel())
    }

    var body: some Scene {
        Window("RoughTrack", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 420)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1300, height: 900)
        .commands {
            StudioCommands(model: model)
        }

        // The mixer, when it's undocked from the main window.
        Window("Mixer", id: "mixer") {
            MixerWindow()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1300, height: 460)

        // A track's channel settings, one window per track.
        WindowGroup("Channel", id: "channel", for: Int.self) { $track in
            if let track {
                ChannelWindow(track: track)
                    .environmentObject(model)
                    .preferredColorScheme(.dark)
            }
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }

        Window("About RoughTrack", id: "about") {
            AboutView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        StudioModel.quitting = true
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        rt.stopStudio()
    }
}

struct StudioCommands: Commands {
    @ObservedObject var model: StudioModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session…") { model.showingNewSession = true }
                .keyboardShortcut("n")

            Button("Import Audio…") { model.chooseAudioToImport() }
                .keyboardShortcut("i", modifiers: [.command, .shift])

            Divider()

            Button("Mix Down…") { model.chooseMixdownFile() }
                .keyboardShortcut("b")
                .disabled(model.mixingDown)
            Button("Export Stems…") { model.exportStems() }
                .disabled(model.mixingDown)

            Divider()

            Menu("Open Session") {
                ForEach(model.sessions, id: \.self) { name in
                    Button(name) { model.openSession(name) }
                        .disabled(name == model.sessionName)
                }
            }
        }

        CommandGroup(replacing: .appInfo) {
            AboutButton()
        }

        CommandGroup(replacing: .help) {
            if model.updateCheckingAvailable {
                Button("Check for Updates…") { model.checkForUpdates() }
            }
        }

        CommandGroup(replacing: .undoRedo) {
            Button(model.canUndo ? "Undo \(model.undoName)" : "Undo") { model.undo() }
                .keyboardShortcut("z")
                .disabled(!model.canUndo)
            Button(model.canRedo ? "Redo \(model.redoName)" : "Redo") { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
        }

        // After the standard Cut, Copy, Paste and Select All, which text fields need.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Delete Clip") { model.deleteSelectedClip() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(model.selectedClip == nil || model.keysAreBusy)
            Button("Split at Playhead") { model.splitAtPlayhead() }
                .keyboardShortcut("t")
        }

        CommandGroup(after: .toolbar) {
            Button(model.showingMixer ? "Hide Mixer" : "Show Mixer") { model.showingMixer.toggle() }
                .keyboardShortcut("x", modifiers: [])
                .disabled(model.keysAreBusy)
            Button(model.mixerUndocked ? "Dock Mixer" : "Undock Mixer") { model.toggleMixerDocking() }
                .keyboardShortcut("x", modifiers: [.command, .option])
            Button(model.showingGrooves ? "Hide Grooves" : "Show Grooves") { model.showingGrooves.toggle() }
                .keyboardShortcut("g", modifiers: [])
                .disabled(model.keysAreBusy)
            Button(model.showingTuner ? "Hide Tuner" : "Show Tuner") { model.showingTuner.toggle() }
                .keyboardShortcut("u")
            Divider()
        }

        CommandMenu("Track") {
            Button("New Audio Track") { model.addTrack(.audio) }
                .keyboardShortcut("a", modifiers: [.command, .option])
            Button("New MIDI Track") { model.addTrack(.midi) }
                .keyboardShortcut("m", modifiers: [.command, .option])
            Button("New Drum Track") { model.addTrack(.drums) }
                .keyboardShortcut("d", modifiers: [.command, .option])
            Divider()
            ChannelSettingsButton(model: model)
            Button("Rescan Plugins") { model.rescanPlugins() }
                .disabled(model.scanningPlugins)
            Divider()
            Button("Delete Track…") {
                if let id = model.selectedTrack, let track = model.tracks.first(where: { $0.id == id }) {
                    model.trackPendingDelete = track
                }
            }
            .disabled(model.selectedTrack == nil || model.tracks.count <= 1)
        }

        // Single keys, as in other DAWs. Off while something takes typing.
        CommandMenu("Transport") {
            Button(model.transport == .stopped ? "Play" : "Stop") { model.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model.keysAreBusy)
            Button("Record") { model.record() }
                .keyboardShortcut("r", modifiers: [])
                .disabled(model.keysAreBusy)
            Button("Go to Beginning") { model.returnToStart() }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(model.keysAreBusy)
            Divider()
            Button(model.cycleEnabled ? "Turn Loop Off" : "Turn Loop On") { model.toggleCycle() }
                .keyboardShortcut("l", modifiers: [])
                .disabled(model.keysAreBusy)
            Button(model.clickEnabled ? "Turn Click Off" : "Turn Click On") { model.toggleClick() }
                .keyboardShortcut("k", modifiers: [])
                .disabled(model.keysAreBusy)
        }
    }
}

/// Opens the selected track's channel window. A view, because only views can open windows.
private struct ChannelSettingsButton: View {
    @ObservedObject var model: StudioModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Channel Settings…") {
            if let track = model.selectedTrack { openWindow(id: "channel", value: track) }
        }
        .keyboardShortcut("e", modifiers: [.command, .option])
        .disabled(model.selectedTrack == nil)
    }
}

/// Opens the About window. A view, because only views can open windows.
private struct AboutButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About RoughTrack") { openWindow(id: "about") }
    }
}

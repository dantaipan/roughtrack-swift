import AppKit
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

/// Pictures of the real window for the README, taken without anyone at the screen:
///
///     RoughTrack --snapshot=<session> --output=<png file> [--mixer] [--tuner] [--grooves]
///                [--channel=<track>] [--2x]
///
/// It opens the session (a name in the sessions folder, or a path to one), waits for its
/// plugins, shows what was asked for and saves the window, or with `--channel` that track's
/// channel window (tracks count from 1). `--2x` saves at Retina resolution. Then it puts
/// back the session RoughTrack reopens and the window's size and place, and quits. macOS
/// asks once for permission to record the screen.
///
/// Every argument starts with `--`, because AppKit takes a bare one for a file to open,
/// and SwiftUI then leaves the main window closed.
struct SnapshotRequest {
    var session: String
    var output: URL
    var mixer = false
    var tuner = false
    var grooves = false
    var channelTrack: Int?
    var scale: CGFloat = 1

    static let current = SnapshotRequest(arguments: CommandLine.arguments)

    init?(arguments: [String]) {
        func value(_ name: String) -> String? {
            arguments.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
        }

        guard let session = value("snapshot"), let output = value("output") else { return nil }
        self.session = URL(fileURLWithPath: session).lastPathComponent
        self.output = URL(fileURLWithPath: output)
        mixer = arguments.contains("--mixer")
        tuner = arguments.contains("--tuner")
        grooves = arguments.contains("--grooves")
        channelTrack = value("channel").flatMap(Int.init)
        scale = arguments.contains("--2x") ? 2 : 1
    }

    /// The main window's content size: taller when the mixer shares it with the lanes.
    var contentSize: CGSize { CGSize(width: 1300, height: mixer ? 980 : 760) }
}

@MainActor
enum Snapshot {
    private static let longestPluginWait: Duration = .seconds(20)

    static func run(_ request: SnapshotRequest, model: StudioModel, openWindow: OpenWindowAction) async {
        let savedFrames = windowFrames()

        // The model learns the open session on its first poll.
        let start = ContinuousClock.now
        while model.sessionName.isEmpty, ContinuousClock.now - start < .seconds(10) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let previousSession = model.sessionName
        log("opened with \(previousSession.isEmpty ? "no session" : previousSession)")

        defer {
            if !previousSession.isEmpty, previousSession != model.sessionName {
                model.openSession(previousSession)
            }
            restoreWindowFrames(savedFrames)
            NSApp.terminate(nil)
        }

        // SwiftUI names the main window after its scene, "main".
        var mainWindow: NSWindow?
        while mainWindow == nil, ContinuousClock.now - start < .seconds(15) {
            mainWindow = NSApp.windows.first { $0.frameAutosaveName == "main" || $0.identifier?.rawValue.hasPrefix("main") == true }
            if mainWindow == nil { try? await Task.sleep(for: .milliseconds(100)) }
        }
        guard let main = mainWindow else {
            log("no main window among \(NSApp.windows.map { "\($0.identifier?.rawValue ?? "?") '\($0.frameAutosaveName)'" })")
            return
        }

        if request.session != model.sessionName {
            guard model.sessions.contains(request.session) else {
                log("no session called \(request.session)")
                return
            }
            model.openSession(request.session)
        }

        // Give the plugins time to start loading, then wait for them to finish.
        try? await Task.sleep(for: .seconds(3))
        let deadline = ContinuousClock.now + longestPluginWait
        while model.restoringPlugins, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }

        model.update = nil
        model.selectedClip = nil
        model.mixerUndocked = false
        model.showingMixer = request.mixer
        model.showingTuner = request.tuner
        model.showingGrooves = request.grooves

        // Resizing for the picture shouldn't change the size RoughTrack opens at.
        main.setFrameAutosaveName("")
        place(main, contentSize: request.contentSize)

        var window = main
        if let number = request.channelTrack {
            guard model.tracks.indices.contains(number - 1) else {
                log("no track \(number)")
                return
            }
            let before = Set(NSApp.windows.map(ObjectIdentifier.init))
            openWindow(id: "channel", value: model.tracks[number - 1].id)
            try? await Task.sleep(for: .seconds(1))
            guard let channel = NSApp.windows.first(where: { !before.contains(ObjectIdentifier($0)) && $0.isVisible }) else {
                log("the channel window didn't open")
                return
            }
            channel.isRestorable = false
            channel.makeKeyAndOrderFront(nil)
            window = channel
        } else {
            main.makeKeyAndOrderFront(nil)
        }

        // Let SwiftUI lay out, and any passing message fade.
        try? await Task.sleep(for: .seconds(1.5))

        do {
            model.clearStatus()
            try? await Task.sleep(for: .milliseconds(200))
            log("capturing")
            try await capture(window, scale: request.scale, to: request.output)
            log("saved \(request.output.path)")
        } catch {
            log("\(error.localizedDescription)")
        }
    }

    /// Top left of the screen, so every snapshot frames the same.
    private static func place(_ window: NSWindow, contentSize: CGSize) {
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: contentSize))
        frame.origin = CGPoint(x: visible.minX + 20, y: visible.maxY - frame.height - 20)
        window.setFrame(frame, display: true)
    }

    private static func capture(_ window: NSWindow, scale: CGFloat, to url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let shared = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw SnapshotError("the window isn't on screen, or RoughTrack may not record the screen yet "
                                + "(System Settings > Privacy & Security > Screen & System Audio Recording)")
        }

        let configuration = SCStreamConfiguration()
        configuration.width = Int(shared.frame.width * scale)
        configuration.height = Int(shared.frame.height * scale)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: shared), configuration: configuration)

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SnapshotError("can't write \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SnapshotError("can't write \(url.path)") }
    }

    // MARK: Leaving the window where it was

    private static func windowFrames() -> [String: Any] {
        UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("NSWindow Frame") }
    }

    private static func restoreWindowFrames(_ saved: [String: Any]) {
        let defaults = UserDefaults.standard
        for key in windowFrames().keys where saved[key] == nil {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in saved {
            defaults.set(value, forKey: key)
        }
    }
}

/// To stderr, unbuffered, so it can be followed while the snapshot runs.
private func log(_ message: String) {
    FileHandle.standardError.write(Data("Snapshot: \(message)\n".utf8))
}

private struct SnapshotError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

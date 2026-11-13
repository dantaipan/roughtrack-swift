import AppKit
import RoughTrackCore
import SwiftUI

/// Plugin editors in windows SwiftUI lays out, as the spike proved: a header above a view
/// the JUCE editor attaches to. The core owns the editor; each frame the window checks its
/// size, so it follows a plugin that resizes itself, and closes if the plugin goes.
@MainActor
final class PluginWindows {
    static let shared = PluginWindows()

    private var windows: [String: PluginWindowController] = [:]

    /// Where each plugin's window was, so it opens there again.
    private var placements: [String: NSPoint] = [:]

    func open(track: Int, slot: Int, title: String, format: String, model: StudioModel) {
        let key = "\(track)-\(slot)"

        if let existing = windows[key] {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }

        guard let controller = PluginWindowController(track: track, slot: slot, title: title, format: format, model: model,
                                                      topLeft: placements[title]) else {
            model.show("Couldn't open that plugin's editor.", warning: true)
            return
        }

        controller.onClose = { [weak self] topLeft in
            self?.placements[title] = topLeft
            self?.windows[key] = nil
        }
        windows[key] = controller
        controller.window.makeKeyAndOrderFront(nil)
    }
}

/// The view the editor's own NSView becomes a child of.
final class EditorContainer: NSView {
    var onResize: ((NSSize) -> Void)?

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?(newSize)
    }
}

private struct EditorContainerView: NSViewRepresentable {
    let container: EditorContainer
    func makeNSView(context: Context) -> EditorContainer { container }
    func updateNSView(_ view: EditorContainer, context: Context) {}
}

private let headerHeight: CGFloat = 32

private struct PluginHeader: View {
    let title: String
    let format: String
    let track: Int
    let slot: Int
    @ObservedObject var model: StudioModel

    var body: some View {
        let insert = model.inserts[track]?.first { $0.slot == slot }

        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(Theme.text))
                .lineLimit(1)
            Text(format)
                .font(.system(size: 11))
                .foregroundStyle(Color(Theme.secondaryText))
            Spacer()
            Toggle("Bypass", isOn: Binding(get: { insert?.bypassed ?? false },
                                           set: { model.setBypassed(track, slot: slot, $0) }))
                .toggleStyle(.checkbox)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .frame(height: headerHeight)
        .background(Color(Theme.ruler))
    }
}

@MainActor
final class PluginWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    var onClose: ((NSPoint) -> Void)?

    private let container = EditorContainer()
    private let handle: Int32
    private var subscription: UUID?
    private var lastSize = NSSize.zero

    init?(track: Int, slot: Int, title: String, format: String, model: StudioModel, topLeft: NSPoint?) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300 + headerHeight),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)

        let container = self.container
        let content = VStack(spacing: 0) {
            PluginHeader(title: title, format: format, track: track, slot: slot, model: model)
            EditorContainerView(container: container)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .preferredColorScheme(.dark)

        let hosting = NSHostingView(rootView: content)
        // The window follows the editor's size, not SwiftUI's idea of it.
        hosting.sizingOptions = []
        window.contentView = hosting
        window.title = title
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)

        // JUCE paints a white background behind an Audio Unit's own view, and Apple's generic
        // views follow the appearance they're in, so in dark mode they'd draw white text on
        // that white. Light mode keeps them readable.
        if format == "AU" { container.appearance = NSAppearance(named: .aqua) }

        // Laid out before the editor attaches, so the container has its place in the window.
        hosting.layoutSubtreeIfNeeded()

        guard let app = rt.app() else { return nil }
        handle = app.openEditor(Int32(track), Int32(slot), Unmanaged.passUnretained(container).toOpaque())
        guard handle != 0 else { return nil }

        super.init()
        window.delegate = self

        let size = app.editorSize(handle)
        if size.resizable { window.styleMask.insert(.resizable) }
        applyEditorSize(NSSize(width: CGFloat(size.width), height: CGFloat(size.height)))

        if let topLeft {
            window.setFrameTopLeftPoint(topLeft)
        } else {
            window.center()
        }

        container.onResize = { [weak self] newSize in
            guard let self, newSize != self.lastSize else { return }
            rt.app()?.resizeEditor(self.handle, Int32(newSize.width.rounded()), Int32(newSize.height.rounded()))
        }

        subscription = FrameClock.shared.subscribe { [weak self] in self?.followEditor() }
    }

    private func applyEditorSize(_ size: NSSize) {
        guard size.width > 0, size.height > 0 else { return }
        lastSize = size
        window.setContentSize(NSSize(width: size.width, height: size.height + headerHeight))
    }

    /// Closes the window if its plugin has gone, and follows a plugin that resizes itself.
    private func followEditor() {
        guard let app = rt.app(), app.isEditorOpen(handle) else {
            finish(closeEditor: false)
            window.close()
            return
        }

        let size = app.editorSize(handle)
        let editorSize = NSSize(width: CGFloat(size.width), height: CGFloat(size.height))
        if editorSize != lastSize, container.frame.size != editorSize {
            applyEditorSize(editorSize)
        }
    }

    func windowWillClose(_ notification: Notification) {
        finish(closeEditor: true)
    }

    private func finish(closeEditor: Bool) {
        guard subscription != nil else { return }
        FrameClock.shared.unsubscribe(subscription)
        subscription = nil
        container.onResize = nil

        // The editor goes before its view does.
        if closeEditor { rt.app()?.closeEditor(handle) }

        let frame = window.frame
        onClose?(NSPoint(x: frame.minX, y: frame.maxY))
    }
}

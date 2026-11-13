import AppKit
import RoughTrackCore

// Plugin scanning relaunches this binary once per plugin, so a crashing plugin
// can't take the app down. Those runs scan and quit without any UI.
let arguments = CommandLine.arguments

if arguments.count >= 2, rt.isPluginScanChild(arguments[1]) {
    NSApplication.shared.setActivationPolicy(.prohibited)
    exit(arguments.count == 5 ? rt.runPluginScanChild(arguments[2], arguments[3], arguments[4]) : 1)
}

RoughTrackApp.main()

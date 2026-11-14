import AppKit
import CxxStdlib
import Foundation
import UniformTypeIdentifiers
import RoughTrackCore

/// What the SwiftUI views show, read from the C++ studio. It polls a revision number
/// rather than taking callbacks, so nothing crosses threads. Things that change every
/// frame (position, levels) aren't here: the views that show them read them directly.
@MainActor
final class StudioModel: ObservableObject {
    struct Track: Identifiable, Equatable {
        let id: Int
        var name: String
        var kind: rt.TrackKind
        var muted: Bool
        var soloed: Bool
        var armed: Bool
        var monitoring: Bool
        var gain: Float
        var pan: Float
        var inverted: Bool
        var firstInput: Int
        var inputChannels: Int
        var ampName: String
        var cabinetName: String
        var ampTone3000: Tone3000Source?
        var cabinetTone3000: Tone3000Source?
        var ampLoading: Bool
        var cabinetLoading: Bool
        var sendReverb: Float
        var sendDelay: Float
    }

    /// Where a track's capture or IR came from on TONE3000.
    struct Tone3000Source: Equatable {
        var toneId: Int
        var title: String
        var model: String
        var creator: String

        init?(_ info: rt.Tone3000Source) {
            guard info.toneId > 0 else { return nil }
            toneId = Int(info.toneId)
            title = String(info.title)
            model = String(info.model)
            creator = String(info.creator)
        }
    }

    struct Insert: Equatable, Identifiable {
        var slot: Int
        var isInstrumentSlot: Bool
        var name: String
        var format: String
        var bypassed: Bool
        var beforeAmp: Bool

        var id: Int { slot }
        var isEmpty: Bool { name.isEmpty }
    }

    struct Plugin: Equatable, Identifiable {
        var index: Int
        var name: String
        var maker: String
        var format: String

        var id: Int { index }
    }

    /// A channel or effects setting, from the engine's own description of it.
    struct Parameter: Identifiable {
        var index: Int
        var label: String
        var suffix: String
        var minimum: Float
        var maximum: Float
        var defaultValue: Float
        var isSwitch: Bool

        var id: Int { index }

        init(_ info: rt.ParameterInfo) {
            index = Int(info.index)
            label = String(info.label)
            suffix = String(info.suffix)
            minimum = info.minimum
            maximum = info.maximum
            defaultValue = info.defaultValue
            isSwitch = info.isSwitch
        }
    }

    struct Clip: Equatable {
        var index: Int
        var start: Int64
        var length: Int64
        var fadeIn: Int64
        var fadeOut: Int64
        var file: String
        var fileOffset: Int64
        var name: String
        var looping: Bool
        var loopEnd: Int64
        var isMidi: Bool

        // Drum parts only
        var groove: String
        var offsetBars: Int
        var bars: Int
        var loopBars: Int
        var isFill: Bool
        var grooveMissing: Bool
        var halfTime: Bool

        var end: Int64 { start + length }

        init(_ info: rt.ClipInfo) {
            index = Int(info.index)
            start = info.start
            length = info.length
            fadeIn = info.fadeIn
            fadeOut = info.fadeOut
            file = String(info.file)
            fileOffset = info.fileOffset
            name = String(info.name)
            looping = info.looping
            loopEnd = info.loopEnd
            isMidi = info.isMidi
            groove = String(info.groove)
            offsetBars = Int(info.offsetBars)
            bars = Int(info.bars)
            loopBars = Int(info.loopBars)
            isFill = info.isFill
            grooveMissing = info.grooveMissing
            halfTime = info.halfTime
        }
    }

    /// A groove in the drum library.
    struct Groove: Equatable, Identifiable {
        var id: String
        var style: String
        var name: String
        var isFill: Bool
        var bars: Int
        var recordedBpm: Int
        var nearTempo: Bool
    }

    /// A finished mixdown or stem export, to tell the player about.
    struct MixdownResult: Identifiable {
        let id = UUID()
        var succeeded: Bool
        var title: String
        var text: String
        var path: String
        var clipped: Bool
    }

    /// What an update check found.
    struct Update: Identifiable {
        let id = UUID()
        var hasRelease: Bool
        var version: String
        var notes: String
        var downloadURL: URL?
        var error: String
    }

    struct ClipID: Equatable {
        var track: Int
        var index: Int
    }

    // Where the sends and returns are in the engine's parameter lists (ChannelStrip.h).
    static let sendReverbIndex: Int32 = 12
    static let sendDelayIndex: Int32 = 13
    static let reverbReturnIndex = 2
    static let delayReturnIndex = 6

    static let quantizeGrids: [(name: String, ticks: Int32)] = [
        ("Quarter Notes", 960), ("Eighth Notes", 480), ("Sixteenth Notes", 240),
        ("Eighth Triplets (Shuffle)", 320), ("Sixteenth Triplets", 160),
    ]

    @Published private(set) var tracks: [Track] = []
    @Published private(set) var inserts: [Int: [Insert]] = [:]
    @Published private(set) var effects: [Plugin] = []
    @Published private(set) var instruments: [Plugin] = []
    @Published private(set) var masterGain: Float = 1
    @Published private(set) var auxValues: [Float] = []
    @Published private(set) var clickEnabled = false
    @Published private(set) var inputChannelCount = 0
    @Published private(set) var scanningPlugins = false
    @Published var showingMixer = false
    @Published var showingGrooves = false {
        didSet { if !showingGrooves { stopGroovePreview() } }
    }
    @Published var showingTuner = false
    @Published private(set) var mixingDown = false
    @Published private(set) var mixdownProgress = 0.0
    @Published var mixdownResult: MixdownResult?
    @Published private(set) var calibrating = false
    @Published var calibrationMessage: (title: String, text: String)?
    @Published private(set) var calibratedLatencyMs = -1.0
    @Published private(set) var controllerName = ""
    @Published private(set) var controllerAutomatic = true
    @Published private(set) var controllerBank = 0
    @Published private(set) var midiInputNames: [String] = []
    @Published var update: Update?
    @Published private(set) var grooves: [Groove] = []
    @Published private(set) var previewingGroove: String?
    @Published private(set) var clips: [Int: [Clip]] = [:]
    @Published private(set) var sessionName = ""
    @Published private(set) var sessions: [String] = []
    @Published private(set) var transport: rt.Transport = .stopped
    @Published private(set) var sampleRate: Double = 48000
    @Published private(set) var tempo: Double = 120
    @Published private(set) var snap: rt.Snap = .bar
    @Published private(set) var cycleEnabled = false
    @Published private(set) var cycleStart: Int64 = 0
    @Published private(set) var cycleEnd: Int64 = 0
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var undoName = ""
    @Published private(set) var redoName = ""
    @Published private(set) var restoringPlugins = false
    @Published private(set) var statusText = ""
    @Published private(set) var statusIsWarning = false

    @Published var selectedClip: ClipID?
    @Published var selectedTrack: Int?
    @Published var showingNewSession = false
    @Published var isEditingText = false
    @Published var alertMessage: String?
    @Published var trackPendingDelete: Track?

    /// Goes up whenever the clips or their timing change, so the timeline redraws once.
    @Published private(set) var layoutRevision = 0

    private var revision: UInt32 = 0
    private var timer: Timer?
    private var statusClearTime = Date.distantFuture

    var app: rt.App? { rt.app() }

    /// TONE3000's sign-in, lists and tones, refreshed with everything else.
    let tone3000 = Tone3000Model()

    let channelParameters: [Parameter]
    let auxParameters: [Parameter]

    /// True when single-key shortcuts mustn't fire, because something is taking typing.
    var keysAreBusy: Bool { showingNewSession || isEditingText }

    init() {
        channelParameters = rt.app()?.channelParameters().map { Parameter($0) } ?? []
        auxParameters = rt.app()?.auxParameters().map { Parameter($0) } ?? []
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
    }

    /// Reads everything again now, so an edit shows without waiting for the next poll.
    func pollNow() {
        poll()
    }

    private func poll() {
        guard let app else { return }

        if app.revision() != revision {
            revision = app.revision()
            reload(app)
        }

        let state = app.transport()
        if state != transport { transport = state }

        let scanning = app.isScanningPlugins()
        if scanning != scanningPlugins { scanningPlugins = scanning }

        if previewingGroove != nil, !app.isPreviewingGroove() { previewingGroove = nil }

        pollLongJobs(app)

        let restoring = app.isRestoringPlugins()
        if restoring != restoringPlugins { restoringPlugins = restoring }

        for message in app.takeMessages() {
            show(String(message.text), warning: message.warning)
        }

        if Date() > statusClearTime {
            statusText = ""
            statusClearTime = .distantFuture
        }

        refreshUndo(app)
    }

    private func reload(_ app: rt.App) {
        tone3000.refresh()

        var newTracks: [Track] = []
        var newClips: [Int: [Clip]] = [:]
        var newInserts: [Int: [Insert]] = [:]

        for info in app.tracks() {
            let id = Int(info.id)
            newTracks.append(Track(id: id, name: String(info.name), kind: info.kind,
                                   muted: info.muted, soloed: info.soloed, armed: info.armed, monitoring: info.monitoring,
                                   gain: info.gain, pan: info.pan, inverted: info.inverted,
                                   firstInput: Int(info.firstInput), inputChannels: Int(info.inputChannels),
                                   ampName: String(info.ampName), cabinetName: String(info.cabinetName),
                                   ampTone3000: Tone3000Source(info.ampTone3000),
                                   cabinetTone3000: Tone3000Source(info.cabinetTone3000),
                                   ampLoading: info.ampLoading, cabinetLoading: info.cabinetLoading,
                                   sendReverb: app.channelParameter(info.id, Self.sendReverbIndex),
                                   sendDelay: app.channelParameter(info.id, Self.sendDelayIndex)))
            newClips[id] = app.clips(info.id).map { Clip($0) }
            newInserts[id] = app.inserts(info.id).map { insert in
                Insert(slot: Int(insert.slot), isInstrumentSlot: insert.isInstrumentSlot, name: String(insert.name),
                       format: String(insert.format), bypassed: insert.bypassed, beforeAmp: insert.beforeAmp)
            }
        }

        if newTracks != tracks { tracks = newTracks }
        if newInserts != inserts { inserts = newInserts }

        let newEffects = app.plugins(false).map { Plugin(index: Int($0.index), name: String($0.name), maker: String($0.maker), format: String($0.format)) }
        if newEffects != effects { effects = newEffects }

        let newInstruments = app.plugins(true).map { Plugin(index: Int($0.index), name: String($0.name), maker: String($0.maker), format: String($0.format)) }
        if newInstruments != instruments { instruments = newInstruments }

        if app.masterGain() != masterGain { masterGain = app.masterGain() }

        let newAux = auxParameters.map { app.auxParameter(Int32($0.index)) }
        if newAux != auxValues { auxValues = newAux }
        if app.clickEnabled() != clickEnabled { clickEnabled = app.clickEnabled() }
        if Int(app.inputChannelCount()) != inputChannelCount { inputChannelCount = Int(app.inputChannelCount()) }

        let newRate = app.sampleRate()
        let newTempo = app.tempo()

        if newTempo != tempo, !grooves.isEmpty { loadGrooves() }

        if newClips != clips || newRate != sampleRate || newTempo != tempo {
            clips = newClips
            sampleRate = newRate
            tempo = newTempo
            layoutRevision += 1
        }

        if let selected = selectedClip, (clips[selected.track]?.count ?? 0) <= selected.index {
            selectedClip = nil
        }

        if let track = selectedTrack, !tracks.contains(where: { $0.id == track }) {
            selectedTrack = nil
        }

        if app.snap() != snap { snap = app.snap() }
        if app.cycleEnabled() != cycleEnabled { cycleEnabled = app.cycleEnabled() }
        if app.cycleStart() != cycleStart { cycleStart = app.cycleStart() }
        if app.cycleEnd() != cycleEnd { cycleEnd = app.cycleEnd() }

        let name = String(app.sessionName())
        if name != sessionName { sessionName = name }

        let controller = String(app.controllerName())
        if controller != controllerName { controllerName = controller }
        if app.controllerAutomatic() != controllerAutomatic { controllerAutomatic = app.controllerAutomatic() }
        if Int(app.controllerBank()) != controllerBank { controllerBank = Int(app.controllerBank()) }
        let inputs = app.midiInputNames().map { String($0) }
        if inputs != midiInputNames { midiInputNames = inputs }

        let latency = app.calibratedLatencyMs()
        if latency != calibratedLatencyMs { calibratedLatencyMs = latency }

        let names = app.sessions().map { String($0) }
        if names != sessions { sessions = names }
    }

    /// Mixdowns, calibration and update checks finish in the core's own time.
    private func pollLongJobs(_ app: rt.App) {
        let mixing = app.isMixingDown()
        if mixing != mixingDown { mixingDown = mixing }
        if mixing { mixdownProgress = app.mixdownProgress() }

        let outcome = app.takeMixdownOutcome()
        if outcome.ready { showMixdownOutcome(outcome) }

        let isCalibrating = app.isCalibrating()
        if isCalibrating != calibrating { calibrating = isCalibrating }

        let calibration = app.takeCalibrationResult()
        if calibration.ready {
            calibratedLatencyMs = app.calibratedLatencyMs()
            calibrationMessage = calibration.succeeded
                ? ("Latency Calibrated", String(format: "Round-trip latency: %.2f ms (%@)", calibration.latencyMs, String(calibration.message)))
                : ("Calibration Didn't Work", String(calibration.message))
        }

        let found = app.takeUpdateOutcome()
        if found.ready {
            update = Update(hasRelease: found.hasRelease, version: String(found.version), notes: String(found.notes),
                            downloadURL: URL(string: String(found.downloadUrl)), error: String(found.error))
        }
    }

    private func showMixdownOutcome(_ outcome: rt.MixdownInfo) {
        let path = String(outcome.path)
        let name = (path as NSString).lastPathComponent

        guard outcome.succeeded else {
            mixdownResult = MixdownResult(succeeded: false, title: outcome.stems ? "Stems Weren't Exported" : "Mixdown Didn't Finish",
                                          text: String(outcome.message), path: path, clipped: false)
            return
        }

        let seconds = Int(outcome.seconds.rounded())
        let length = String(format: "%d:%02d", seconds / 60, seconds % 60)
        let peak = String(format: "%.1f", outcome.peakDecibels)
        var text = outcome.stems
            ? "\(outcome.numStems) stems in \(name), \(length) long, the loudest peaking at \(peak) dBFS."
            : "\(name), \(length) long, peaking at \(peak) dBFS."

        if outcome.clipped {
            let lower = String(format: "%.1f", (Double(outcome.peakDecibels) * 10).rounded(.up) / 10)
            text += "\n\nThat's over full scale, so the loudest parts are clipped. Lower the master fader by at least \(lower) dB and mix down again."
        }

        mixdownResult = MixdownResult(succeeded: true, title: outcome.stems ? "Stems Exported" : "Mixed Down",
                                      text: text, path: path, clipped: outcome.clipped)
    }

    private func refreshUndo(_ app: rt.App) {
        if app.canUndo() != canUndo { canUndo = app.canUndo() }
        if app.canRedo() != canRedo { canRedo = app.canRedo() }

        let undo = String(app.undoName())
        if undo != undoName { undoName = undo }

        let redo = String(app.redoName())
        if redo != redoName { redoName = redo }
    }

    /// Clears the status bar now, as snapshots do so a passing message isn't in the picture.
    func clearStatus() {
        statusText = ""
        statusIsWarning = false
        statusClearTime = .distantFuture
    }

    /// Shows a line in the status bar for a few seconds.
    func show(_ text: String, warning: Bool = false) {
        statusText = text
        statusIsWarning = warning
        statusClearTime = Date().addingTimeInterval(warning ? 12 : 6)
    }

    // MARK: - Transport

    func togglePlay() {
        guard let app else { return }
        if app.transport() == .stopped { app.play() } else { app.stop() }
    }

    func play() { app?.play() }
    func stop() { app?.stop() }
    func returnToStart() { app?.returnToStart() }

    func record() {
        guard let app else { return }
        let error = String(app.record())
        if !error.isEmpty { alertMessage = error }
    }

    func seek(to position: Int64) { app?.seek(position) }

    func toggleCycle() { app?.setCycleEnabled(!cycleEnabled); pollNow() }
    func setCycle(_ start: Int64, _ end: Int64) { app?.setCycleRange(start, end); pollNow() }
    func clearCycle() { app?.clearCycle(); pollNow() }

    func setSnap(_ newSnap: rt.Snap) { app?.setSnap(newSnap); pollNow() }

    // MARK: - Tracks

    func setMuted(_ track: Track, _ value: Bool) { app?.setMuted(Int32(track.id), value) }
    func setSoloed(_ track: Track, _ value: Bool) { app?.setSoloed(Int32(track.id), value) }
    func setArmed(_ track: Track, _ value: Bool) { app?.setArmed(Int32(track.id), value) }
    func setMonitoring(_ track: Track, _ value: Bool) { app?.setMonitoring(Int32(track.id), value) }

    func addTrack(_ kind: rt.TrackKind) {
        guard let app else { return }
        let track = Int(app.addTrack(kind))
        pollNow()
        if track >= 0 { selectedTrack = track }
    }

    func deleteTrack(_ track: Track) {
        guard let app else { return }
        let error = String(app.deleteTrack(Int32(track.id)))
        if !error.isEmpty { show(error, warning: true) }
        pollNow()
    }

    func moveTrack(_ track: Int, to position: Int) {
        app?.moveTrack(Int32(track), Int32(position))
        pollNow()
    }

    func renameTrack(_ track: Track, to name: String) {
        app?.renameTrack(Int32(track.id), std.string(name))
        pollNow()
    }

    // MARK: - Mixer

    func setGain(_ track: Int, _ gain: Float) { app?.setGain(Int32(track), gain) }
    func setPan(_ track: Int, _ pan: Float) { app?.setPan(Int32(track), pan) }
    func setInverted(_ track: Track, _ value: Bool) { app?.setInverted(Int32(track.id), value) }
    func setInput(_ track: Track, first: Int, channels: Int) { app?.setInput(Int32(track.id), Int32(first), Int32(channels)) }
    func setMasterGain(_ gain: Float) { app?.setMasterGain(gain) }
    func setTempo(_ tempo: Double) { app?.setTempo(tempo); pollNow() }
    func toggleClick() { app?.setClickEnabled(!clickEnabled); pollNow() }

    func channelParameter(_ track: Int, _ parameter: Int) -> Float {
        app?.channelParameter(Int32(track), Int32(parameter)) ?? 0
    }

    func setChannelParameter(_ track: Int, _ parameter: Int, _ value: Float) {
        app?.setChannelParameter(Int32(track), Int32(parameter), value)
    }

    func auxParameter(_ parameter: Int) -> Float { app?.auxParameter(Int32(parameter)) ?? 0 }
    func setAuxParameter(_ parameter: Int, _ value: Float) { app?.setAuxParameter(Int32(parameter), value) }

    /// Each returns what went wrong, or nil.
    func loadAmp(_ track: Int, _ url: URL) -> String? {
        let error = String(app?.loadAmp(Int32(track), std.string(url.path)) ?? "")
        pollNow()
        return error.isEmpty ? nil : error
    }

    func loadCabinet(_ track: Int, _ url: URL) -> String? {
        let error = String(app?.loadCabinet(Int32(track), std.string(url.path)) ?? "")
        pollNow()
        return error.isEmpty ? nil : error
    }

    func removeAmp(_ track: Int) { app?.removeAmp(Int32(track)); pollNow() }
    func clearCabinet(_ track: Int) { app?.clearCabinet(Int32(track)); pollNow() }
    var ampFolder: URL { URL(fileURLWithPath: String(app?.ampFolder() ?? "")) }

    // MARK: - Plugins

    func loadPlugin(_ track: Int, slot: Int, plugin: Plugin) {
        let error = String(app?.loadPlugin(Int32(track), Int32(slot), Int32(plugin.index)) ?? "")
        if !error.isEmpty { show(error, warning: true) }
    }

    func removePlugin(_ track: Int, slot: Int) { app?.removePlugin(Int32(track), Int32(slot)); pollNow() }
    func setBypassed(_ track: Int, slot: Int, _ value: Bool) { app?.setPluginBypassed(Int32(track), Int32(slot), value); pollNow() }
    func setBeforeAmp(_ track: Int, slot: Int, _ value: Bool) { app?.setPluginBeforeAmp(Int32(track), Int32(slot), value); pollNow() }
    func rescanPlugins() { app?.rescanPlugins() }

    func openPluginWindow(_ track: Int, slot: Int) {
        guard let insert = inserts[track]?.first(where: { $0.slot == slot }), !insert.isEmpty else { return }
        let trackName = tracks.first { $0.id == track }?.name ?? ""
        PluginWindows.shared.open(track: track, slot: slot, title: "\(insert.name) – \(trackName)", format: insert.format, model: self)
    }

    // MARK: - Clips

    var isStopped: Bool { transport == .stopped }

    /// Says why, and returns false, if the transport is running.
    func canEdit() -> Bool {
        if isStopped { return true }
        show("Stop the transport to edit.")
        return false
    }

    func select(_ clip: ClipID?) {
        selectedClip = clip
        if let clip { selectedTrack = clip.track }
    }

    func deleteSelectedClip() {
        guard let clip = selectedClip, canEdit() else { return }
        app?.deleteClip(Int32(clip.track), Int32(clip.index))
        selectedClip = nil
        pollNow()
    }

    func split(_ clip: ClipID, at position: Int64, placeFreely: Bool = false) {
        guard canEdit() else { return }
        app?.splitClip(Int32(clip.track), Int32(clip.index), position, placeFreely)
        pollNow()
    }

    /// Splits whichever clip on the selected track the playhead is over.
    func splitAtPlayhead() {
        guard let app, let track = selectedTrack ?? selectedClip?.track else {
            show("Select a track or clip to split.")
            return
        }

        let position = app.position()
        guard let clip = clips[track]?.last(where: { $0.start < position && position < $0.end }) else {
            show("The playhead isn't over a clip on that track.")
            return
        }

        split(ClipID(track: track, index: clip.index), at: position, placeFreely: true)
    }

    func setLooping(_ clip: ClipID, _ value: Bool) {
        guard canEdit() else { return }
        app?.setClipLooping(Int32(clip.track), Int32(clip.index), value)
        pollNow()
    }

    /// A drum part's groove at half speed, for a half-time feel.
    func setHalfTime(_ clip: ClipID, _ value: Bool) {
        guard canEdit() else { return }
        app?.setPartHalfTime(Int32(clip.track), Int32(clip.index), value)
        pollNow()
    }

    func quantize(_ clip: ClipID, gridTicks: Int32) {
        guard canEdit() else { return }
        app?.quantizeClip(Int32(clip.track), Int32(clip.index), gridTicks)
        pollNow()
    }

    // MARK: - Drums

    /// Reads the drum library, which loads it the first time.
    func loadGrooves() {
        guard let app else { return }
        let loaded = app.grooves().map { info in
            Groove(id: String(info.id), style: String(info.style), name: String(info.name), isFill: info.isFill,
                   bars: Int(info.bars), recordedBpm: Int(info.recordedBpm), nearTempo: info.nearTempo)
        }
        if loaded != grooves { grooves = loaded }
    }

    var grooveStyles: [String] {
        var seen = Set<String>()
        return grooves.map(\.style).filter { seen.insert($0).inserted }
    }

    /// One style's grooves or fills, those suited to the tempo first.
    func grooves(style: String, fills: Bool) -> [Groove] {
        let matching = grooves.filter { $0.style == style && $0.isFill == fills }
        return matching.filter(\.nearTempo) + matching.filter { !$0.nearTempo }
    }

    func groove(_ id: String) -> Groove? { grooves.first { $0.id == id } }

    /// The drum track grooves go to and preview through: the selected track if it's a drum
    /// track, otherwise the first one.
    var drumTrack: Int? {
        if let selected = selectedTrack, tracks.first(where: { $0.id == selected })?.kind == .drums { return selected }
        return tracks.first { $0.kind == .drums }?.id
    }

    func toggleGroovePreview(_ groove: Groove) {
        guard let app else { return }

        if previewingGroove == groove.id {
            stopGroovePreview()
            return
        }

        guard let track = drumTrack else {
            show("Add a drum track to hear grooves.")
            return
        }

        app.startGroovePreview(Int32(track), std.string(groove.id))
        previewingGroove = app.isPreviewingGroove() ? groove.id : nil
    }

    func stopGroovePreview() {
        guard previewingGroove != nil else { return }
        app?.stopGroovePreview()
        previewingGroove = nil
    }

    /// Puts a groove on a drum track in the bar a position falls in. With no track given,
    /// it goes on a new drum track.
    func addPart(_ grooveID: String, onto track: Int?, at position: Int64) {
        guard let app, canEdit() else { return }
        stopGroovePreview()

        var target = track
        if target == nil {
            let made = Int(app.addTrack(.drums))
            guard made >= 0 else { pollNow(); return }
            target = made
        }

        let error = String(app.addPart(Int32(target!), std.string(grooveID), max(0, position)))
        if !error.isEmpty { show(error, warning: true) }
        pollNow()
        selectedTrack = target
    }

    /// Adds a groove at the playhead's bar on the drum track, or a new one if there isn't one.
    func addPartAtPlayhead(_ groove: Groove) {
        addPart(groove.id, onto: drumTrack, at: app?.position() ?? 0)
    }

    func hits(groove: String, offsetBars: Int, bars: Int, halfTime: Bool) -> [rt.DrumHitInfo] {
        app.map { Array($0.grooveHits(std.string(groove), Int32(offsetBars), Int32(bars), halfTime)) } ?? []
    }

    func takes(for track: Int) -> [String] {
        app?.takes(Int32(track)).map { String($0) } ?? []
    }

    func addTakeAtPlayhead(_ track: Int, file: String) {
        guard canEdit() else { return }
        app?.addTakeAtPlayhead(Int32(track), std.string(file))
        pollNow()
    }

    /// Asks for audio files and imports them at the playhead: onto the selected audio track
    /// if there's one file, otherwise each onto a new track, as a drop below the tracks does.
    func chooseAudioToImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.message = "Choose audio files to import at the playhead."
        panel.prompt = "Import"

        guard panel.runModal() == .OK, !panel.urls.isEmpty, let app else { return }

        let selected = tracks.first { $0.id == selectedTrack && $0.kind == .audio }
        let onto = panel.urls.count == 1 ? selected?.id : nil
        importAudio(panel.urls, onto: onto, at: app.position())
    }

    func importAudio(_ urls: [URL], onto track: Int?, at position: Int64) {
        guard let app else { return }
        for url in urls {
            app.importAudio(std.string(url.path), Int32(track ?? -1), position)
        }
    }

    // MARK: - Mixdown, calibration, controller and updates

    func chooseMixdownFile() {
        guard let app, canEdit() else { return }
        let folder = URL(fileURLWithPath: String(app.mixdownFolder()))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let panel = NSSavePanel()
        panel.title = "Mix Down"
        panel.allowedContentTypes = [.wav]
        panel.directoryURL = folder
        panel.nameFieldStringValue = "\(sessionName).wav"
        panel.prompt = "Mix Down"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        startMixdown(url.path, stems: false)
    }

    func exportStems() {
        guard let app, canEdit() else { return }
        startMixdown(String(app.nextStemsFolder()), stems: true)
    }

    private func startMixdown(_ path: String, stems: Bool) {
        guard let app else { return }
        stopGroovePreview()
        let error = String(app.startMixdown(std.string(path), stems))
        if !error.isEmpty { show(error, warning: true) }
        mixdownProgress = 0
        pollNow()
    }

    func cancelMixdown() { app?.cancelMixdown() }

    func startCalibration() {
        guard let app else { return }
        let error = String(app.startCalibration())
        if !error.isEmpty { calibrationMessage = ("Can't Calibrate", error) }
        pollNow()
    }

    func chooseController(_ name: String?) {
        if let name { app?.chooseController(std.string(name)) } else { app?.chooseControllerAutomatically() }
        pollNow()
    }

    var updateCheckingAvailable: Bool { app?.updateCheckingAvailable() ?? false }
    var version: String { String(app?.version() ?? "") }

    func checkForUpdates() { app?.checkForUpdates(true) }
    func skipUpdate(_ version: String) { app?.skipUpdate(std.string(version)) }

    var checksForUpdatesAutomatically: Bool {
        get { app?.checksForUpdatesAutomatically() ?? false }
        set { objectWillChange.send(); app?.setChecksForUpdatesAutomatically(newValue) }
    }

    // MARK: - Undo and sessions

    func undo() { app?.undo(); pollNow() }
    func redo() { app?.redo(); pollNow() }

    func openSession(_ name: String) {
        selectedClip = nil
        selectedTrack = nil
        app?.openSession(std.string(name))
        pollNow()
    }

    /// Returns what went wrong, or nil if the session was created.
    func newSession(_ name: String) -> String? {
        guard let app else { return "The studio isn't running." }
        let error = String(app.newSession(std.string(name)))
        pollNow()
        return error.isEmpty ? nil : error
    }
}

import AppKit
import CxxStdlib
import QuartzCore
import RoughTrackCore
import SwiftUI
import UniformTypeIdentifiers

/// The tracks' regions, one Core Animation layer each, edited with the mouse. Scrolling
/// moves a container layer, and paths are cached, so nothing is redrawn while it
/// scrolls or plays. The edit rules themselves are in the C++ core: a drag asks it for
/// a preview as the mouse moves, and commits when it's let go.
final class LanesNSView: NSView {
    private struct Drag {
        var clip: StudioModel.ClipID
        var zone: rt.DragZone
        var startX: CGFloat
        var distance: Int64 = 0
        var placeFreely = false
    }

    private struct Hit {
        var row: Int
        var clip: StudioModel.Clip?
        var zone: rt.DragZone
    }

    private struct DropTarget {
        var row: Int
        var position: Int64
        var isNewTrack: Bool
        var groove: String?
    }

    private static let titleHeight: CGFloat = 15
    private static let edgeGrab: CGFloat = 6
    private static let handleSize: CGFloat = 8

    /// Below this, a part's hits are too close together to be worth drawing.
    private static let minimumPixelsPerBarForHits: CGFloat = 24

    private let geometry: TimelineGeometry
    weak var model: StudioModel?

    private var observer: UUID?
    private var clockSubscription: UUID?
    private let content = CALayer()
    private let playhead = CALayer()

    private var tracks: [StudioModel.Track] = []
    private var clips: [Int: [StudioModel.Clip]] = [:]
    private var selected: StudioModel.ClipID?
    private var hovered: StudioModel.ClipID?
    private var cycle: (enabled: Bool, start: Int64, end: Int64) = (false, 0, 0)

    private var drag: Drag?
    private var preview: (track: Int, clips: [StudioModel.Clip])?
    private var drop: DropTarget?

    /// Waveforms, drum hits and notes, drawn once and kept until the zoom changes.
    private var paths: [String: CGPath] = [:]

    init(geometry: TimelineGeometry) {
        self.geometry = geometry
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.window.cgColor
        layer?.masksToBounds = true

        content.anchorPoint = .zero
        layer?.addSublayer(content)

        playhead.backgroundColor = Theme.playhead.cgColor
        playhead.zPosition = 10
        layer?.addSublayer(playhead)

        registerForDraggedTypes([.fileURL, .string])

        observer = geometry.observe { [weak self] zoomChanged in
            if zoomChanged {
                self?.paths.removeAll()
                self?.rebuild()
            } else {
                self?.moveContent()
            }
        }
        clockSubscription = FrameClock.shared.subscribe { [weak self] in self?.movePlayhead() }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        let observer = observer, subscription = clockSubscription, geometry = geometry
        MainActor.assumeIsolated {
            geometry.stopObserving(observer)
            FrameClock.shared.unsubscribe(subscription)
        }
    }

    override var isFlipped: Bool { true }

    func show(tracks: [StudioModel.Track], clips: [Int: [StudioModel.Clip]], selected: StudioModel.ClipID?,
              cycle: (enabled: Bool, start: Int64, end: Int64)) {
        self.tracks = tracks
        self.clips = clips
        self.selected = selected
        self.cycle = cycle

        // A new set of clips is the edit landing, so any preview is finished with.
        if drag == nil { preview = nil }
        rebuild()
    }

    override func layout() {
        super.layout()
        rebuild()
    }

    // MARK: - Geometry

    private func shownClips(_ track: Int) -> [StudioModel.Clip] {
        if let preview, preview.track == track { return preview.clips }
        return clips[track] ?? []
    }

    private func regionFrame(row: Int, _ clip: StudioModel.Clip) -> CGRect {
        let x = geometry.contentX(forSample: clip.start)
        let width = max(2, geometry.contentX(forSample: clip.end) - x)
        return CGRect(x: x, y: CGFloat(row) * Theme.laneHeight + 2, width: width, height: Theme.laneHeight - 5)
    }

    /// The region and its loop's repeats.
    private func extentFrame(row: Int, _ clip: StudioModel.Clip) -> CGRect {
        var frame = regionFrame(row: row, clip)
        if clip.looping, clip.loopEnd > clip.end {
            frame.size.width = max(frame.width, geometry.contentX(forSample: clip.loopEnd) - frame.minX)
        }
        return frame
    }

    /// The handle on a region's top edge that sets a fade, at the inner end of that fade.
    private func handleFrame(row: Int, _ clip: StudioModel.Clip, _ zone: rt.DragZone) -> CGRect {
        let region = regionFrame(row: row, clip)
        let x = zone == .fadeIn ? geometry.contentX(forSample: clip.start + clip.fadeIn)
                                : geometry.contentX(forSample: clip.end - clip.fadeOut)
        let left = min(max(x - Self.handleSize / 2, region.minX), max(region.minX, region.maxX - Self.handleSize))
        return CGRect(x: left, y: region.minY, width: Self.handleSize, height: Self.handleSize)
    }

    private func hit(at point: CGPoint) -> Hit? {
        let row = Int(point.y / Theme.laneHeight)
        guard point.y >= 0, row < tracks.count else { return nil }

        let track = tracks[row]
        let contentPoint = CGPoint(x: point.x + geometry.scrollX, y: point.y)

        for clip in shownClips(track.id).reversed() {
            let extent = extentFrame(row: row, clip)
            guard extent.contains(contentPoint) else { continue }

            // The fade handles sit on the trim edges' corners, so they're found first.
            if track.kind == .audio {
                for zone in [rt.DragZone.fadeIn, .fadeOut] where handleFrame(row: row, clip, zone).insetBy(dx: -2, dy: -2).contains(contentPoint) {
                    return Hit(row: row, clip: clip, zone: zone)
                }
            }

            var zone = rt.DragZone.body
            if extent.width > Self.edgeGrab * 3 {
                if contentPoint.x < extent.minX + Self.edgeGrab { zone = .start }
                else if contentPoint.x > extent.maxX - Self.edgeGrab { zone = .end }
            }
            return Hit(row: row, clip: clip, zone: zone)
        }

        return Hit(row: row, clip: nil, zone: .body)
    }

    // MARK: - Drawing

    /// Lays out every lane and region at the current zoom. Called when the clips, selection
    /// or zoom change and while dragging, never while scrolling or playing.
    private func rebuild() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        content.sublayers = nil
        let scale = window?.backingScaleFactor ?? 2
        let width = max(bounds.width + geometry.scrollX, 1) + 10000

        for row in tracks.indices {
            let top = CGFloat(row) * Theme.laneHeight

            let lane = CALayer()
            lane.frame = CGRect(x: 0, y: top, width: width, height: Theme.laneHeight)
            lane.backgroundColor = (row % 2 == 0 ? Theme.lanes : Theme.laneAlternate).cgColor
            content.addSublayer(lane)

            let line = CALayer()
            line.frame = CGRect(x: 0, y: top + Theme.laneHeight - 1, width: width, height: 1)
            line.backgroundColor = Theme.separator.cgColor
            content.addSublayer(line)

            if tracks[row].kind == .drums, shownClips(tracks[row].id).isEmpty {
                let hint = CATextLayer()
                hint.string = "Drag a groove here, or right-click"
                hint.fontSize = 11
                hint.foregroundColor = Theme.secondaryText.cgColor
                hint.contentsScale = scale
                hint.frame = CGRect(x: 10, y: top + Theme.laneHeight / 2 - 8, width: 300, height: 16)
                content.addSublayer(hint)
            }
        }

        // The loop range shows faintly behind the regions.
        if cycle.enabled, cycle.end > cycle.start {
            let band = CALayer()
            let x = geometry.contentX(forSample: cycle.start)
            band.frame = CGRect(x: x, y: 0, width: geometry.contentX(forSample: cycle.end) - x,
                                height: max(bounds.height, CGFloat(tracks.count) * Theme.laneHeight))
            band.backgroundColor = Theme.cycle.withAlphaComponent(0.07).cgColor
            content.addSublayer(band)
        }

        for (row, track) in tracks.enumerated() {
            for clip in shownClips(track.id) {
                let id = StudioModel.ClipID(track: track.id, index: clip.index)
                content.addSublayer(makeRegion(clip, row: row, track: track, scale: scale,
                                               isSelected: id == selected, isHovered: id == hovered))
            }
        }

        if let drop { content.addSublayer(makeDropIndicator(drop, width: width, scale: scale)) }

        moveContent()
    }

    private func makeRegion(_ clip: StudioModel.Clip, row: Int, track: StudioModel.Track, scale: CGFloat,
                            isSelected: Bool, isHovered: Bool) -> CALayer {
        let frame = regionFrame(row: row, clip)
        let colour = track.kind != .drums ? Theme.colour(for: track.kind)
                   : (clip.grooveMissing ? Theme.record : (clip.isFill ? Theme.drumFill : Theme.colour(for: .drums)))
        let container = CALayer()
        container.frame = extentFrame(row: row, clip)

        // A loop's repeats run on after the region, lighter, with a dashed outline.
        if clip.looping, container.frame.width > frame.width + 1 {
            let repeats = CAShapeLayer()
            let repeatFrame = CGRect(x: frame.width, y: 0, width: container.frame.width - frame.width, height: frame.height)
            repeats.path = CGPath(roundedRect: repeatFrame.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 4, cornerHeight: 4, transform: nil)
            repeats.fillColor = colour.withAlphaComponent(0.18).cgColor
            repeats.strokeColor = colour.withAlphaComponent(0.7).cgColor
            repeats.lineDashPattern = [4, 3]
            container.addSublayer(repeats)

            let mark = CATextLayer()
            mark.string = "↻"
            mark.fontSize = 11
            mark.foregroundColor = colour.cgColor
            mark.contentsScale = scale
            mark.frame = CGRect(x: frame.width + 4, y: 1, width: 14, height: 14)
            container.addSublayer(mark)

            // A drum part marks each bar its groove starts over.
            if track.kind == .drums, clip.bars > 0 {
                let barWidth = frame.width / CGFloat(clip.bars)
                var x = frame.width + barWidth * CGFloat(clip.bars)
                while x < container.frame.width - 1, barWidth > 4 {
                    let restart = CALayer()
                    restart.frame = CGRect(x: x.rounded(), y: 3, width: 1, height: frame.height - 6)
                    restart.backgroundColor = colour.withAlphaComponent(0.5).cgColor
                    container.addSublayer(restart)
                    x += barWidth * CGFloat(clip.bars)
                }
            }
        }

        let region = CALayer()
        region.frame = CGRect(origin: .zero, size: frame.size)
        region.cornerRadius = 4
        region.masksToBounds = true
        region.backgroundColor = colour.withAlphaComponent(track.muted ? 0.25 : 0.55).cgColor
        region.borderColor = (isSelected ? Theme.selection : colour.withAlphaComponent(0.9)).cgColor
        region.borderWidth = isSelected ? 2 : 1
        container.addSublayer(region)

        let titleBar = CALayer()
        titleBar.frame = CGRect(x: 0, y: 0, width: frame.width, height: Self.titleHeight)
        titleBar.backgroundColor = colour.withAlphaComponent(track.muted ? 0.4 : 0.85).cgColor
        region.addSublayer(titleBar)

        if frame.width > 24 {
            let title = CATextLayer()
            title.string = clip.name
            title.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            title.fontSize = 10
            title.foregroundColor = NSColor(white: 0.08, alpha: 1).cgColor
            title.contentsScale = scale
            title.truncationMode = .end
            title.frame = CGRect(x: 4, y: 1, width: frame.width - 8, height: Self.titleHeight - 2)
            region.addSublayer(title)
        }

        let ink = NSColor(white: 0.05, alpha: track.muted ? 0.35 : 0.75).cgColor

        switch track.kind {
        case .audio where !clip.file.isEmpty:
            let wave = CAShapeLayer()
            wave.path = waveformPath(clip, size: frame.size)
            wave.fillColor = ink
            region.addSublayer(wave)

        case .midi where !clip.file.isEmpty:
            let notes = CAShapeLayer()
            notes.path = notesPath(clip, track: track.id, size: frame.size)
            notes.fillColor = ink
            region.addSublayer(notes)

        case .drums where !clip.grooveMissing && clip.bars > 0 && frame.width / CGFloat(clip.bars) >= Self.minimumPixelsPerBarForHits:
            let (inPart, inRepeats) = hitPaths(clip, partSize: frame.size, extentWidth: container.frame.width)
            let hits = CAShapeLayer()
            hits.path = inPart
            hits.fillColor = ink
            region.addSublayer(hits)

            if let inRepeats {
                let repeated = CAShapeLayer()
                repeated.path = inRepeats
                repeated.fillColor = colour.withAlphaComponent(0.6).cgColor
                container.addSublayer(repeated)
            }

        default:
            break
        }

        if track.kind == .audio {
            addFades(to: region, clip: clip, size: frame.size)

            if isSelected || isHovered {
                for zone in [rt.DragZone.fadeIn, .fadeOut] {
                    let handle = CALayer()
                    var handleRect = handleFrame(row: row, clip, zone)
                    handleRect.origin.x -= frame.minX
                    handleRect.origin.y -= frame.minY
                    handle.frame = handleRect
                    handle.cornerRadius = 2
                    handle.backgroundColor = Theme.selection.cgColor
                    handle.borderColor = NSColor(white: 0, alpha: 0.5).cgColor
                    handle.borderWidth = 1
                    container.addSublayer(handle)
                }
            }
        }

        return container
    }

    /// A take's peaks as a filled shape, cached by take, stretch and size.
    private func waveformPath(_ clip: StudioModel.Clip, size: CGSize) -> CGPath {
        let points = Int(min(size.width, 8000))
        let key = "\(clip.file)|\(clip.fileOffset)|\(clip.length)|\(points)|\(Int(size.height))"
        if let cached = paths[key] { return cached }

        let path = CGMutablePath()

        if let app = rt.app(), points > 0 {
            let peaks = Array(app.waveform(std.string(clip.file), clip.fileOffset, clip.length, Int32(points)))
            let waveHeight = size.height - Self.titleHeight - 4
            let middle = Self.titleHeight + 2 + waveHeight / 2
            let step = size.width / CGFloat(points)

            path.move(to: CGPoint(x: 0, y: middle))
            for (i, peak) in peaks.enumerated() {
                path.addLine(to: CGPoint(x: CGFloat(i) * step, y: middle - CGFloat(peak) * waveHeight / 2))
            }
            for (i, peak) in peaks.enumerated().reversed() {
                path.addLine(to: CGPoint(x: CGFloat(i) * step, y: middle + CGFloat(peak) * waveHeight / 2))
            }
            path.closeSubpath()
        }

        paths[key] = path
        return path
    }

    /// A MIDI clip's notes as small bars, spread over its own range of pitches, as
    /// RoughTrack draws them.
    private func notesPath(_ clip: StudioModel.Clip, track: Int, size: CGSize) -> CGPath {
        let key = "notes|\(clip.file)|\(clip.fileOffset)|\(clip.length)|\(Int(size.width))|\(Int(size.height))"
        if let cached = paths[key] { return cached }

        let path = CGMutablePath()
        let notes = rt.app().map { Array($0.midiNotes(Int32(track), std.string(clip.file), clip.fileOffset, clip.length)) } ?? []

        if !notes.isEmpty, clip.length > 0 {
            let lowest = notes.map { Int($0.pitch) }.min() ?? 0
            let highest = notes.map { Int($0.pitch) }.max() ?? 0
            let noteHeight: CGFloat = 2
            let top = Self.titleHeight + 3
            let bottom = size.height - 3
            let rowHeight = (bottom - top - noteHeight) / CGFloat(max(1, highest - lowest))
            let scale = size.width / CGFloat(clip.length)

            for note in notes {
                let left = max(0, CGFloat(note.start) * scale)
                let right = min(size.width, CGFloat(note.start + note.length) * scale)
                guard right > left else { continue }
                let y = bottom - noteHeight - CGFloat(Int(note.pitch) - lowest) * rowHeight
                path.addRect(CGRect(x: left, y: y, width: max(1, right - left), height: noteHeight))
            }
        }

        paths[key] = path
        return path
    }

    /// A drum part's hits, kick at the bottom to cymbals at the top, louder ones taller:
    /// one path for the part itself and one for its loop's repeats, if it has any.
    private func hitPaths(_ clip: StudioModel.Clip, partSize: CGSize, extentWidth: CGFloat) -> (CGPath, CGPath?) {
        let totalBars = max(clip.bars, clip.loopBars)
        let key = "hits|\(clip.groove)|\(clip.offsetBars)|\(clip.bars)|\(totalBars)|\(clip.halfTime)|\(Int(partSize.width))|\(Int(partSize.height))"

        if let part = paths[key] {
            return (part, totalBars > clip.bars ? paths[key + "|repeats"] : nil)
        }

        let part = CGMutablePath()
        let repeats = CGMutablePath()
        let pixelsPerBeat = partSize.width / CGFloat(clip.bars * 4)
        let top = Self.titleHeight + 3
        let rowHeight = (partSize.height - 3 - top) / 5
        let partBeats = Double(clip.bars * 4)

        for hit in model?.hits(groove: clip.groove, offsetBars: clip.offsetBars, bars: totalBars, halfTime: clip.halfTime) ?? [] {
            let x = CGFloat(hit.beat) * pixelsPerBeat
            guard x >= 0, x < extentWidth else { continue }
            let height = max(2, rowHeight * CGFloat(0.35 + 0.55 * hit.velocity))
            let rowBottom = partSize.height - 3 - CGFloat(hit.row) * rowHeight
            let rect = CGRect(x: x, y: rowBottom - height, width: 1.5, height: height)
            if hit.beat < partBeats { part.addRect(rect) } else { repeats.addRect(rect) }
        }

        paths[key] = part
        paths[key + "|repeats"] = repeats
        return (part, totalBars > clip.bars ? repeats : nil)
    }

    /// Shades what each fade takes away, under an equal-power curve like the one the engine plays.
    private func addFades(to region: CALayer, clip: StudioModel.Clip, size: CGSize) {
        let top = Self.titleHeight
        let bottom = size.height

        for isFadeIn in [true, false] {
            let fade = isFadeIn ? clip.fadeIn : clip.fadeOut
            guard fade > 0 else { continue }

            let fadeWidth = geometry.contentX(forSample: fade)
            let shade = CGMutablePath()
            let curve = CGMutablePath()

            for step in 0...16 {
                let t = CGFloat(step) / 16
                let gain = sin(t * .pi / 2)
                let x = isFadeIn ? t * fadeWidth : size.width - t * fadeWidth
                let point = CGPoint(x: x, y: bottom - gain * (bottom - top))
                if step == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            }

            let edgeX = isFadeIn ? 0 : size.width
            shade.move(to: CGPoint(x: edgeX, y: top))
            shade.addPath(curve)
            shade.addLine(to: CGPoint(x: isFadeIn ? fadeWidth : size.width - fadeWidth, y: top))
            shade.closeSubpath()

            let shadeLayer = CAShapeLayer()
            shadeLayer.path = shade
            shadeLayer.fillColor = NSColor(white: 0, alpha: 0.35).cgColor
            region.addSublayer(shadeLayer)

            let curveLayer = CAShapeLayer()
            curveLayer.path = curve
            curveLayer.fillColor = nil
            curveLayer.strokeColor = NSColor(white: 1, alpha: 0.7).cgColor
            curveLayer.lineWidth = 1
            region.addSublayer(curveLayer)
        }
    }

    private func makeDropIndicator(_ target: DropTarget, width: CGFloat, scale: CGFloat) -> CALayer {
        let indicator = CALayer()
        let top = CGFloat(target.row) * Theme.laneHeight

        let lane = CALayer()
        lane.frame = CGRect(x: 0, y: top, width: width, height: Theme.laneHeight)
        lane.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
        lane.borderColor = Theme.cycle.withAlphaComponent(0.6).cgColor
        lane.borderWidth = 1
        indicator.addSublayer(lane)

        let x = geometry.contentX(forSample: target.position)
        let line = CALayer()
        line.frame = CGRect(x: x, y: top, width: 2, height: Theme.laneHeight)
        line.backgroundColor = Theme.cycle.cgColor
        indicator.addSublayer(line)

        if target.isNewTrack {
            let label = CATextLayer()
            label.string = target.groove == nil ? "New track" : "New drum track"
            label.fontSize = 11
            label.foregroundColor = Theme.secondaryText.cgColor
            label.contentsScale = scale
            label.frame = CGRect(x: x + 8, y: top + Theme.laneHeight / 2 - 8, width: 120, height: 16)
            indicator.addSublayer(label)
        }

        return indicator
    }

    private func moveContent() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.position = CGPoint(x: -geometry.scrollX, y: 0)
        CATransaction.commit()
        movePlayhead()
    }

    private func movePlayhead() {
        guard let app = rt.app() else { return }
        let position = app.position()
        var x = geometry.x(forSample: position)

        // While playing, turn the page when the playhead nears the right edge.
        if app.transport() != .stopped, x > bounds.width * 0.92, bounds.width > 100 {
            geometry.scroll(by: bounds.width * 0.75)
            x = geometry.x(forSample: position)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playhead.frame = CGRect(x: x.rounded(), y: 0, width: 1, height: bounds.height)
        CATransaction.commit()
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard drag == nil else { return }
        let found = hit(at: convert(event.locationInWindow, from: nil))
        if let found, found.clip != nil, found.zone != .body {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }

        // The fade handles show on the region under the mouse.
        let over = found.flatMap { hit in hit.clip.map { StudioModel.ClipID(track: tracks[hit.row].id, index: $0.index) } }
        if over != hovered {
            hovered = over
            rebuild()
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        if hovered != nil {
            hovered = nil
            rebuild()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        let point = convert(event.locationInWindow, from: nil)

        guard let found = hit(at: point) else {
            model.select(nil)
            return
        }

        let track = tracks[found.row]
        model.selectedTrack = track.id

        guard let clip = found.clip else {
            model.select(nil)
            return
        }

        let id = StudioModel.ClipID(track: track.id, index: clip.index)
        model.select(id)
        selected = id

        guard model.canEdit() else {
            rebuild()
            return
        }

        drag = Drag(clip: id, zone: found.zone, startX: point.x)
        rebuild()
    }

    override func mouseDragged(with event: NSEvent) {
        guard var current = drag, let app = rt.app() else { return }
        let point = convert(event.locationInWindow, from: nil)

        current.distance = geometry.samples(forPixels: point.x - current.startX)
        current.placeFreely = event.modifierFlags.contains(.command)
        drag = current

        let previewed = app.previewDrag(Int32(current.clip.track), Int32(current.clip.index), current.zone,
                                        current.distance, current.placeFreely)
        preview = (current.clip.track, previewed.map { StudioModel.Clip($0) })
        rebuild()
    }

    override func mouseUp(with event: NSEvent) {
        guard let finished = drag else { return }
        drag = nil

        if finished.distance != 0 {
            rt.app()?.commitDrag(Int32(finished.clip.track), Int32(finished.clip.index), finished.zone,
                                 finished.distance, finished.placeFreely)
        }

        preview = nil
        model?.pollNow()
        rebuild()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let model else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        guard let found = hit(at: point) else { return nil }

        let track = tracks[found.row]
        model.selectedTrack = track.id

        if track.kind == .drums {
            rebuild()
            return drumMenu(track: track, clip: found.clip, at: geometry.sample(forX: point.x), model: model)
        }

        var items: [NSMenuItem] = []

        if let clip = found.clip {
            let id = StudioModel.ClipID(track: track.id, index: clip.index)
            model.select(id)
            let position = geometry.sample(forX: point.x)

            items.append(ActionMenuItem("Split Here") { [weak model] in model?.split(id, at: position) })
            items.append(ActionMenuItem("Delete Clip") { [weak model] in
                model?.select(id)
                model?.deleteSelectedClip()
            })
            items.append(ActionMenuItem("Loop Until Next Part", checked: clip.looping) { [weak model] in
                model?.setLooping(id, !clip.looping)
            })

            if clip.isMidi {
                let quantize = NSMenuItem(title: "Quantize", action: nil, keyEquivalent: "")
                quantize.submenu = NSMenu.manual(StudioModel.quantizeGrids.map { grid in
                    ActionMenuItem(grid.name) { [weak model] in model?.quantize(id, gridTicks: grid.ticks) }
                })
                items.append(quantize)
            }

            items.append(.separator())
        }

        let takes = model.takes(for: track.id)
        let addTake = NSMenuItem(title: "Add Take at Playhead", action: nil, keyEquivalent: "")
        addTake.submenu = NSMenu.manual(takes.map { file in
            ActionMenuItem((file as NSString).lastPathComponent) { [weak model] in model?.addTakeAtPlayhead(track.id, file: file) }
        })
        addTake.isEnabled = !takes.isEmpty
        items.append(addTake)

        rebuild()
        return NSMenu.manual(items)
    }

    /// Grooves and fills to add in the bar clicked, and what can be done to a part.
    private func drumMenu(track: StudioModel.Track, clip: StudioModel.Clip?, at position: Int64, model: StudioModel) -> NSMenu {
        model.loadGrooves()
        var items: [NSMenuItem] = []

        for fills in [false, true] {
            let item = NSMenuItem(title: fills ? "Add Fill Here" : "Add Groove Here", action: nil, keyEquivalent: "")
            item.submenu = NSMenu.manual(model.grooveStyles.map { style in
                let styleItem = NSMenuItem(title: style, action: nil, keyEquivalent: "")
                let grooves = model.grooves(style: style, fills: fills)
                var grooveItems: [NSMenuItem] = []

                for (i, groove) in grooves.enumerated() {
                    if i > 0, !groove.nearTempo, grooves[i - 1].nearTempo { grooveItems.append(.separator()) }
                    let title = groove.name
                    grooveItems.append(ActionMenuItem(title) { [weak model] in
                        model?.addPart(groove.id, onto: track.id, at: position)
                    })
                }

                styleItem.submenu = NSMenu.manual(grooveItems)
                styleItem.isEnabled = !grooves.isEmpty
                return styleItem
            })
            item.isEnabled = !model.grooves.isEmpty
            items.append(item)
        }

        if let clip {
            let id = StudioModel.ClipID(track: track.id, index: clip.index)
            model.select(id)
            items.append(.separator())
            items.append(ActionMenuItem("Split Here") { [weak model] in model?.split(id, at: position) })
            items.append(ActionMenuItem("Delete Part") { [weak model] in
                model?.select(id)
                model?.deleteSelectedClip()
            })
            items.append(ActionMenuItem("Loop Until Next Part", checked: clip.looping) { [weak model] in
                model?.setLooping(id, !clip.looping)
            })
            items.append(ActionMenuItem("Half Time", checked: clip.halfTime) { [weak model] in
                model?.setHalfTime(id, !clip.halfTime)
            })
        }

        return NSMenu.manual(items)
    }

    override func scrollWheel(with event: NSEvent) {
        if !handleTimelineScroll(event, in: self, geometry: geometry) {
            super.scrollWheel(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        geometry.zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil).x)
    }

    // MARK: - Dropping files from Finder

    private func audioURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audio) == true }
    }

    private func grooveID(_ info: NSDraggingInfo) -> String? {
        info.draggingPasteboard.string(forType: .string).flatMap(GrooveDrag.grooveID(from:))
    }

    /// One file over an audio lane goes onto that track. Several files, or a drop
    /// anywhere else, each get a new track. A groove goes onto a drum lane, in the bar
    /// it's over, or onto a new drum track.
    private func dropTarget(_ info: NSDraggingInfo) -> DropTarget? {
        if let groove = grooveID(info) {
            let point = convert(info.draggingLocation, from: nil)
            let row = Int(max(0, point.y) / Theme.laneHeight)
            let ontoLane = row < tracks.count && tracks[row].kind == .drums
            let samplesPerBar = geometry.secondsPerBar * geometry.sampleRate
            let bar = max(0, (Double(geometry.sample(forX: point.x)) / samplesPerBar).rounded(.down))
            return DropTarget(row: ontoLane ? row : tracks.count, position: Int64((bar * samplesPerBar).rounded()),
                              isNewTrack: !ontoLane, groove: groove)
        }

        let urls = audioURLs(info)
        guard !urls.isEmpty, let app = rt.app() else { return nil }

        let point = convert(info.draggingLocation, from: nil)
        let row = Int(max(0, point.y) / Theme.laneHeight)
        let ontoLane = urls.count == 1 && row < tracks.count && tracks[row].kind == .audio
        let placeFreely = NSEvent.modifierFlags.contains(.command)
        let position = app.snapPosition(max(0, geometry.sample(forX: point.x)), placeFreely)

        return DropTarget(row: ontoLane ? row : tracks.count, position: position, isNewTrack: !ontoLane)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let target = dropTarget(sender)
        if target?.row != drop?.row || target?.position != drop?.position {
            drop = target
            rebuild()
        }
        return target == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        drop = nil
        rebuild()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let target = dropTarget(sender), let model else { return false }
        let track = target.isNewTrack ? nil : tracks[target.row].id

        if let groove = target.groove {
            model.addPart(groove, onto: track, at: target.position)
        } else {
            model.importAudio(audioURLs(sender), onto: track, at: target.position)
        }
        drop = nil
        rebuild()
        return true
    }
}

struct LanesView: NSViewRepresentable {
    let geometry: TimelineGeometry
    @EnvironmentObject private var model: StudioModel

    func makeNSView(context: Context) -> LanesNSView {
        let view = LanesNSView(geometry: geometry)
        view.model = model
        return view
    }

    func updateNSView(_ view: LanesNSView, context: Context) {
        geometry.sampleRate = model.sampleRate
        geometry.tempo = model.tempo
        view.show(tracks: model.tracks, clips: model.clips, selected: model.selectedClip,
                  cycle: (model.cycleEnabled, model.cycleStart, model.cycleEnd))
    }
}

#include "roughtrack/ClipDrag.h"

#include "roughtrack/Loops.h"

namespace roughtrack
{

// Lifted from RoughTrack's TimelineView::dragClip.
ClipList dragClip (const ClipList& clips,
                   int index,
                   DragZone zone,
                   juce::int64 distance,
                   SnapGrid grid,
                   double beat,
                   juce::int64 loopEnd)
{
    if (! juce::isPositiveAndBelow (index, (int) clips.size()))
        return clips;

    const auto& clip = clips[(size_t) index];

    // A click that doesn't move anything mustn't nudge a clip onto the grid.
    if (distance == 0)
        return clips;

    // The edge snaps where it lands, not by how far it moved, so an edge that started off
    // the grid ends up on it.
    const auto snapped = [grid, beat] (juce::int64 position) { return snapToGrid (position, grid, beat); };

    switch (zone)
    {
        // Nothing before zero can play, so a clip stops there rather than hiding its start.
        case DragZone::body:
            return moveClip (clips, index, juce::jmax ((juce::int64) 0, snapped (clip.timelineStart + distance)));

        case DragZone::start:
            return trimClipStart (clips, index, juce::jmax ((juce::int64) 0, snapped (clip.timelineStart + distance)));

        case DragZone::end:
            // Dragging a loop's end keeps what it was playing as separate clips, up to where it's let go.
            if (clip.loopsToNext)
                return bakeLoop (clips, index, snapped (loopEnd + distance));

            return trimClipEnd (clips, index, snapped (clip.timelineEnd() + distance));

        // Fades are usually short, so they're set freely rather than on the grid.
        case DragZone::fadeIn:
            return setClipFades (clips, index, clip.fadeIn + distance, clip.fadeOut);

        case DragZone::fadeOut:
            return setClipFades (clips, index, clip.fadeIn, clip.fadeOut - distance);
    }

    return clips;
}

const char* dragEditName (DragZone zone) noexcept
{
    switch (zone)
    {
        case DragZone::body:    return "Move Clip";
        case DragZone::fadeIn:  return "Fade In";
        case DragZone::fadeOut: return "Fade Out";
        case DragZone::start:
        case DragZone::end:     break;
    }

    return "Trim Clip";
}

DrumPartList dragPart (const DrumPartList& parts, int index, DragZone zone, int bars, int loopEnd)
{
    if (! juce::isPositiveAndBelow (index, (int) parts.size()) || bars == 0)
        return parts;

    const auto& part = parts[(size_t) index];

    switch (zone)
    {
        case DragZone::body:  return movePart (parts, index, part.startBar + bars);
        case DragZone::start: return trimPartStart (parts, index, part.startBar + bars);
        case DragZone::end:
        {
            if (! part.loopsToNext)
                return trimPartEnd (parts, index, part.endBar() + bars);

            auto unlooped = parts;
            unlooped[(size_t) index].loopsToNext = false;
            return trimPartEnd (unlooped, index, juce::jmax (loopEnd, part.endBar()) + bars);
        }
        case DragZone::fadeIn:
        case DragZone::fadeOut: break;
    }

    return parts;
}

const char* partDragEditName (DragZone zone) noexcept
{
    return zone == DragZone::body ? "Move Part" : "Trim Part";
}

} // namespace roughtrack

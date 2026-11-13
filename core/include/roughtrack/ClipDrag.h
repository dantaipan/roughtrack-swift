#pragma once

#include "roughtrack/Clip.h"
#include "roughtrack/Drums.h"
#include "roughtrack/Grid.h"

namespace roughtrack
{

/** Which part of a clip a drag holds. */
enum class DragZone
{
    body,
    start,
    end,
    fadeIn,
    fadeOut
};

/** Where a clip drag lands: the clips with one moved or trimmed by a distance, the
    dragged edge snapped to the grid. A looping clip's end turns into the repeats it
    was playing. A fade handle sets that fade, off the grid. Everything is in the
    clips' own units, samples or ticks, and beat is how many of them make a beat.
*/
ClipList dragClip (const ClipList&,
                   int index,
                   DragZone,
                   juce::int64 distance,
                   SnapGrid,
                   double beat,
                   juce::int64 loopEnd);

/** The undo name for a drag that held this zone. */
const char* dragEditName (DragZone) noexcept;

/** Where a drum part drag lands, moved or trimmed by whole bars. Parts have no fades,
    so those zones change nothing. Dragging a looping part's end sets that end by hand
    from where its loop stopped, and it stops looping.
*/
DrumPartList dragPart (const DrumPartList&, int index, DragZone, int bars, int loopEnd);

/** The undo name for a part drag. */
const char* partDragEditName (DragZone) noexcept;

} // namespace roughtrack

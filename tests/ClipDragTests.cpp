#include "roughtrack/ClipDrag.h"
#include "roughtrack/Midi.h"

#include <catch2/catch_test_macros.hpp>

// Ported from RoughTrack's TimelineViewTests, which drove the same rules through the JUCE view.

using namespace roughtrack;

namespace
{

constexpr double beat = 24000.0; // 120 bpm at 48 kHz

Clip makeClip (juce::int64 start, juce::int64 length, juce::int64 offset = 0, juce::int64 fileLength = 960000)
{
    Clip clip;
    clip.file = juce::File ("/nonexistent/take.wav");
    clip.timelineStart = start;
    clip.length = length;
    clip.fileOffset = offset;
    clip.fileLength = fileLength;
    return clip;
}

} // namespace

TEST_CASE ("Dragging a clip's body moves it")
{
    const auto clips = dragClip ({ makeClip (120000, 48000) }, 0, DragZone::body, 24000, SnapGrid::off, beat, 0);

    CHECK (clips[0].timelineStart == 144000);
    CHECK (clips[0].length == 48000);
    CHECK (juce::String (dragEditName (DragZone::body)) == "Move Clip");
}

TEST_CASE ("A clip dragged left stops at zero")
{
    const ClipList clips { makeClip (24000, 48000) };

    CHECK (dragClip (clips, 0, DragZone::body, -100000, SnapGrid::off, beat, 0)[0].timelineStart == 0);
    CHECK (dragClip (clips, 0, DragZone::body, -100000, SnapGrid::bar, beat, 0)[0].timelineStart == 0);
    CHECK (dragClip (clips, 0, DragZone::body, -100000, SnapGrid::bar, beat, 0)[0].fileOffset == 0);

    // Trimming its start back can't go before zero either, even with earlier audio to show.
    const auto trimmed = dragClip ({ makeClip (24000, 48000, 30000) }, 0, DragZone::start, -100000, SnapGrid::off, beat, 0);
    CHECK (trimmed[0].timelineStart == 0);
    CHECK (trimmed[0].fileOffset == 6000);
    CHECK (trimmed[0].length == 72000);
}

TEST_CASE ("Dragging a clip's left edge trims its start")
{
    const auto clips = dragClip ({ makeClip (120000, 48000) }, 0, DragZone::start, 12000, SnapGrid::off, beat, 0);

    CHECK (clips[0].timelineStart == 132000);
    CHECK (clips[0].fileOffset == 12000);
    CHECK (clips[0].length == 36000);
    CHECK (juce::String (dragEditName (DragZone::start)) == "Trim Clip");
}

TEST_CASE ("Dragging a clip's right edge trims its end")
{
    const auto clips = dragClip ({ makeClip (120000, 48000) }, 0, DragZone::end, -12000, SnapGrid::off, beat, 0);

    CHECK (clips[0].timelineStart == 120000);
    CHECK (clips[0].length == 36000);
}

TEST_CASE ("Clicking without dragging changes nothing, even off the grid")
{
    const ClipList clips { makeClip (1234, 48000) };

    for (const auto zone : { DragZone::body, DragZone::start, DragZone::end, DragZone::fadeIn, DragZone::fadeOut })
        CHECK (dragClip (clips, 0, zone, 0, SnapGrid::bar, beat, 0) == clips);
}

TEST_CASE ("A MIDI clip recorded off the grid lands on it when trimmed")
{
    // Record was pressed a little after bar 2 and Stop a little before bar 5.
    Clip clip;
    clip.file = juce::File ("/keys.mid");
    clip.timelineStart = 3840 + 137;
    clip.length = 3 * 3840 - 300;
    clip.fileLength = clip.length;

    // Each edge is dragged inward, short of a bar line, and lands on it.
    auto clips = dragClip ({ clip }, 0, DragZone::start, 3500, SnapGrid::bar, ticksPerBeat, 0);
    CHECK (clips[0].timelineStart == 2 * 3840);

    clips = dragClip (clips, 0, DragZone::end, -3500, SnapGrid::bar, ticksPerBeat, 0);
    CHECK (clips[0].timelineEnd() == 3 * 3840);
    CHECK (clips[0].length == 3840);
}

TEST_CASE ("A moved clip's start lands on the grid, and Off leaves it where it's dropped")
{
    const auto clip = makeClip (1234, 96000, 0, 96000);

    CHECK (dragClip ({ clip }, 0, DragZone::body, 50000, SnapGrid::beat, beat, 0)[0].timelineStart == 48000);
    CHECK (dragClip ({ clip }, 0, DragZone::body, 50000, SnapGrid::off, beat, 0)[0].timelineStart == 51234);
}

TEST_CASE ("Dragging a loop's end snaps where the repeats stop")
{
    auto clip = makeClip (0, 96000, 0, 96000);
    clip.loopsToNext = true;

    // The loop ran to 500000; dragged back a little, it stops on the nearest bar.
    const auto baked = dragClip ({ clip }, 0, DragZone::end, -30000, SnapGrid::bar, beat, 500000);

    CHECK (baked.back().timelineEnd() == 480000);
    CHECK_FALSE (baked.front().loopsToNext);
}

TEST_CASE ("Dragging a clip's top corners sets its fades, off the grid")
{
    auto clips = dragClip ({ makeClip (120000, 480000) }, 0, DragZone::fadeIn, 24000, SnapGrid::bar, beat, 0);
    CHECK (clips[0].fadeIn == 24000);
    CHECK (clips[0].timelineStart == 120000);
    CHECK (juce::String (dragEditName (DragZone::fadeIn)) == "Fade In");

    clips = dragClip (clips, 0, DragZone::fadeOut, -36000, SnapGrid::bar, beat, 0);
    CHECK (clips[0].fadeOut == 36000);
    CHECK (clips[0].length == 480000);
    CHECK (juce::String (dragEditName (DragZone::fadeOut)) == "Fade Out");

    // Dragging the fade-in handle back shortens that fade.
    clips = dragClip (clips, 0, DragZone::fadeIn, -12000, SnapGrid::bar, beat, 0);
    CHECK (clips[0].fadeIn == 12000);
}

TEST_CASE ("A fade drag that doesn't move changes nothing")
{
    const ClipList clips { makeClip (0, 48000) };

    CHECK (dragClip (clips, 0, DragZone::fadeIn, 0, SnapGrid::bar, beat, 0) == clips);
    CHECK (dragClip (clips, 0, DragZone::fadeOut, -4800, SnapGrid::bar, beat, 0)[0].fadeOut == 4800);
}

TEST_CASE ("A drag on a clip that isn't there changes nothing")
{
    const ClipList clips { makeClip (0, 48000) };

    CHECK (dragClip (clips, 3, DragZone::body, 4800, SnapGrid::off, beat, 0) == clips);
}

TEST_CASE ("A drum part drag moves and trims by whole bars, and a looping end stops looping")
{
    const DrumPartList parts { { "beat", 2, 2, 0 }, { "fill", 8, 1, 0, false } };

    CHECK (dragPart (parts, 0, DragZone::body, 3, 4)[0].startBar == 5);
    CHECK (dragPart (parts, 0, DragZone::body, -5, 4)[0].startBar == 0);
    CHECK (dragPart (parts, 0, DragZone::start, 1, 4)[0] == DrumPart { "beat", 3, 1, 1 });
    CHECK (dragPart (parts, 0, DragZone::end, -5, 4)[0].bars == 1);
    CHECK (dragPart (parts, 0, DragZone::fadeIn, 2, 4) == parts);
    CHECK (dragPart (parts, 5, DragZone::body, 2, 4) == parts);

    auto looping = parts;
    looping[0].loopsToNext = true;
    const auto unlooped = dragPart (looping, 0, DragZone::end, -1, 8);
    CHECK (! unlooped[0].loopsToNext);
    CHECK (unlooped[0].endBar() == 7);
}

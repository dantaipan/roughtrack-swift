#pragma once

#include <juce_core/juce_core.h>

#include <cmath>
#include <vector>

namespace roughtrack
{

enum class DrumPiece
{
    kick,
    snare,
    sideStick,
    hiHatClosed,
    hiHatOpen,
    hiHatPedal,
    tomHigh,
    tomMid,
    tomLow,
    crash,
    crash2,
    ride,
    rideBell,
    count
};

const char* getPieceName (DrumPiece) noexcept;

inline constexpr int beatsPerBar = 4;

/** A drummer can land this far ahead of the beat. A hit that early belongs to the
    bar it's leading into, so a part keeps the push into its first downbeat.
*/
inline constexpr double grooveEarlyBeats = 0.125;

struct DrumHit
{
    double beat = 0.0;
    DrumPiece piece = DrumPiece::kick;
    float velocity = 1.0f;
};

/** A drummer's performance, timed in beats so it follows the session's tempo. */
struct Groove
{
    juce::String id, style, name;
    bool isFill = false;
    int bars = 0;
    int recordedBpm = 0;

    /** In time order, from grooveEarlyBeats before the first bar. */
    std::vector<DrumHit> hits;

    /** Where each bar starts in hits, plus one past the end. */
    std::vector<int> barStarts;
};

/** A groove plays at any tempo, but sounds most natural close to where it was recorded. */
bool isNearTempo (const Groove&, double beatsPerMinute) noexcept;

class GrooveLibrary
{
public:
    /** Returns false if the file can't be read. */
    bool load (const juce::File&);

    const std::vector<Groove>& getGrooves() const noexcept { return grooves; }
    const Groove* find (const juce::String& id) const noexcept;

private:
    std::vector<Groove> grooves;
};

/** A groove placed on the timeline, in whole bars. It loops if it's longer than
    the groove, and because it's counted in bars it moves with the tempo.
*/
struct DrumPart
{
    juce::String groove;
    int startBar = 0;
    int bars = 0;
    int offsetBars = 0;

    /** Runs on until the next part on the track starts, or to the end of the song. */
    bool loopsToNext = false;

    /** Plays the groove at half speed, so each of its bars fills two of the song's: the
        snare on 2 and 4 lands on 3, for a half-time feel. offsetBars still counts the
        song's bars.
    */
    bool halfTime = false;

    int endBar() const noexcept { return startBar + bars; }
    bool operator== (const DrumPart&) const = default;
};

/** Calls back with each of a groove's hits heard in one bar of a part, and the hit's beat
    counted from that bar's start (a little below zero for a push into it). barInPart
    counts the song's bars from the groove's start, and wraps when the part loops it. At
    half time each bar of the groove fills two, and a push comes twice as early.
*/
template <typename Callback>
void forEachHitInBar (const Groove& groove, int barInPart, bool halfTime, Callback&& callback)
{
    if (groove.bars <= 0 || (int) groove.barStarts.size() <= groove.bars)
        return;

    const auto songBar = juce::negativeAwareModulo (barInPart, groove.bars * (halfTime ? 2 : 1));
    const auto barInGroove = halfTime ? songBar / 2 : songBar;

    for (auto i = groove.barStarts[(size_t) barInGroove]; i < groove.barStarts[(size_t) barInGroove + 1]; ++i)
    {
        const auto& hit = groove.hits[(size_t) i];

        if (! halfTime)
        {
            callback (hit.beat - barInGroove * beatsPerBar, hit, i);
            continue;
        }

        // Which of the two bars this hit falls in, a push counting with the bar it leads into.
        const auto half = (int) std::floor ((hit.beat + grooveEarlyBeats) / 2.0) - barInGroove * 2;

        if (half == songBar % 2)
            callback (hit.beat * 2.0 - songBar * beatsPerBar, hit, i);
    }
}

/** Later parts play over earlier ones, so a fill replaces the bars it covers. */
using DrumPartList = std::vector<DrumPart>;

/** The part heard in a bar, or -1. */
int findPartAt (const DrumPartList&, int bar) noexcept;

DrumPartList movePart (DrumPartList, int index, int newStartBar);
DrumPartList trimPartStart (DrumPartList, int index, int newStartBar);
DrumPartList trimPartEnd (DrumPartList, int index, int newEndBar);
DrumPartList splitPart (DrumPartList, int index, int bar);
DrumPartList removePart (DrumPartList, int index);

} // namespace roughtrack

#pragma once

#include <juce_core/juce_core.h>

#include <optional>
#include <vector>

/** Finding out whether a newer RoughTrack is out, from its GitHub releases. Nothing is
    sent beyond an ordinary request for the latest release.
*/
namespace updates
{

/** Where to ask for the latest release. Left empty, no request is ever made and the
    checker stays off.
*/
inline constexpr auto latestReleaseUrl = "https://api.github.com/repos/dantaipan/roughtrack-swift/releases/latest";

inline bool isUpdateCheckingAvailable() { return juce::String (latestReleaseUrl).isNotEmpty(); }

struct Release
{
    juce::String version;     // As tagged, such as "v0.10.0".
    juce::String notes;       // The release notes, in Markdown.
    juce::String pageUrl;
    juce::String downloadUrl; // The disk image, or the release page if there isn't one.
};

/** Compares version numbers part by part, so 0.10 is newer than 0.9. A leading "v" is ignored. */
bool isNewerVersion (const juce::String& candidate, const juce::String& current);

/** Reads GitHub's answer for the latest release, or nothing if it isn't one. */
std::optional<Release> parseLatestRelease (const juce::var& json);

/** Whether to tell the player about a release. Automatic checks leave out a version they
    chose to skip; asking from the menu always shows it.
*/
bool shouldOffer (const Release&, const juce::String& currentVersion, const juce::String& skippedVersion, bool isManual);

/** The settings key for the last automatic check. It's RoughTrack Swift's own, apart from
    the JUCE RoughTrack's "lastUpdateCheck" in the settings they share. */
inline constexpr auto lastCheckKey = "lastUpdateCheckByVersion";

/** What lastCheckKey holds after a check: the version that checked, and when. */
juce::String lastCheckRecord (const juce::String& version, juce::int64 nowMs);

/** Whether an automatic check is due: once a day for each version. A check by any other
    version, such as a newer test build or another copy of RoughTrack sharing the
    settings, doesn't count, so it never keeps an older install from hearing of a release.
*/
bool isAutomaticCheckDue (const juce::String& lastCheck, const juce::String& currentVersion, juce::int64 nowMs);

/** A stretch of release notes in one style, ready to show. */
struct NoteRun
{
    juce::String text;
    bool bold = false;
    bool heading = false;
};

/** Turns the Markdown of release notes into styled text. Headings, bullets, bold and links
    come through; images, and the download section and checksum that only make sense on the
    web page, are left out.
*/
std::vector<NoteRun> notesToRuns (const juce::String& markdown);
juce::String runsToText (const std::vector<NoteRun>&);

/** Asks GitHub for the latest release. Blocks for up to the timeout, so it's run off the
    message thread. On failure it says why in error.
*/
std::optional<Release> fetchLatestRelease (const juce::String& currentVersion, juce::String& error);

} // namespace updates

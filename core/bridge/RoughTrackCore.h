#pragma once

// What the SwiftUI app can see and do. Swift imports this header through C++
// interop, so it stays free of JUCE: plain C++ types only. Everything here
// belongs to the main thread, which is also JUCE's message thread.

#include <cstdint>
#include <string>
#include <vector>

// Swift treats an immortal reference as a class it never retains or releases.
#define ROUGHTRACK_SWIFT_IMMORTAL                         \
    __attribute__ ((swift_attr ("import_reference")))     \
    __attribute__ ((swift_attr ("retain:immortal")))      \
    __attribute__ ((swift_attr ("release:immortal")))

namespace rt
{

enum class TrackKind : int
{
    audio,
    drums,
    midi
};

enum class Transport : int
{
    stopped,
    playing,
    recording
};

/** Which part of a clip a drag holds. */
enum class DragZone : int
{
    body,
    start,
    end,
    fadeIn,
    fadeOut
};

/** What moves, trims, splits and loop ranges land on. */
enum class Snap : int
{
    bar,
    beat,
    sixteenth,
    off
};

struct TrackInfo
{
    int id = 0;
    std::string name;
    TrackKind kind = TrackKind::audio;
    bool muted = false;
    bool soloed = false;
    bool armed = false;
    bool monitoring = false;

    // The mixer
    float gain = 1.0f;
    float pan = 0.0f;
    bool inverted = false;
    int firstInput = 0;
    int inputChannels = 1;

    /** The built-in amp's capture and cabinet impulse, by file name, or empty. */
    std::string ampName;
    std::string cabinetName;
};

/** A channel or effects setting, described well enough to draw a control for it. */
struct ParameterInfo
{
    int index = 0;
    std::string id;
    std::string label;
    std::string suffix;
    float minimum = 0.0f;
    float maximum = 1.0f;
    float defaultValue = 0.0f;
    bool isSwitch = false;
};

/** A plugin in the scanned list. */
struct PluginInfo
{
    int index = 0;
    std::string name;
    std::string maker;
    std::string format;
};

/** What's in one of a track's plugin slots. */
struct InsertInfo
{
    int slot = 0;
    bool isInstrumentSlot = false;
    std::string name;
    std::string format;
    bool bypassed = false;
    bool beforeAmp = false;
};

struct EditorSize
{
    int width = 0;
    int height = 0;
    bool resizable = false;
};

/** A clip or drum part, placed in samples on the timeline whatever the track's own units. */
struct ClipInfo
{
    int index = 0;
    std::int64_t start = 0;
    std::int64_t length = 0;
    std::int64_t fadeIn = 0;
    std::int64_t fadeOut = 0;

    /** Audio clips only: the take, and where in it the clip starts, in samples. */
    std::string file;
    std::int64_t fileOffset = 0;

    std::string name;

    /** Repeats until the next clip; loopEnd is where its repeats stop. */
    bool looping = false;
    std::int64_t loopEnd = 0;

    /** On a MIDI track; such clips can be quantized. Its file and offset are set too,
        the offset in samples, for drawing its notes.
    */
    bool isMidi = false;

    /** Drum parts only: the groove, how many bars into it the part starts, and how long it
        is in bars, counting its loop.
    */
    std::string groove;
    int offsetBars = 0;
    int bars = 0;
    int loopBars = 0;
    bool isFill = false;
    bool grooveMissing = false;
};

/** A groove in the drum library. */
struct GrooveInfo
{
    std::string id;
    std::string style;
    std::string name;
    bool isFill = false;
    int bars = 0;
    int recordedBpm = 0;

    /** Recorded close enough to the session's tempo to sound natural at it. */
    bool nearTempo = false;
};

/** One drum hit, for drawing: beats from the start of a part, and a row from the kick (0)
    through the snare, toms and hi-hat to the cymbals (4).
*/
struct DrumHitInfo
{
    double beat = 0.0;
    int row = 0;
    float velocity = 0.0f;
};

/** One note of a MIDI clip, in samples from the clip's start. */
struct NoteInfo
{
    std::int64_t start = 0;
    std::int64_t length = 0;
    int pitch = 0;
    float velocity = 0.0f;
};

struct TunerInfo
{
    bool running = false;
    bool hasNote = false;
    std::string note;
    double cents = 0.0;

    /** Which track and input it's listening to. */
    std::string source;
};

/** How a latency calibration went; ready is false until there's a result to show. */
struct CalibrationInfo
{
    bool ready = false;
    bool succeeded = false;
    int latencySamples = 0;
    double latencyMs = 0.0;
    std::string message;
};

/** A finished mixdown or stem export; ready is false until one finishes. */
struct MixdownInfo
{
    bool ready = false;
    bool succeeded = false;
    std::string message;
    std::string path;
    bool stems = false;
    double seconds = 0.0;
    float peakDecibels = -100.0f;
    bool clipped = false;
    int numStems = 0;
};

/** The answer to an update check; ready is false until there is one. */
struct UpdateInfo
{
    bool ready = false;
    bool manual = false;
    bool hasRelease = false;
    std::string version;
    std::string notes;
    std::string pageUrl;
    std::string downloadUrl;
    std::string error;
};

struct Message
{
    std::string text;
    bool warning = false;
};

struct AudioDeviceInfo
{
    std::string name;
    double sampleRate = 0.0;
    int bufferSize = 0;
    std::vector<std::string> devices;
    std::vector<double> sampleRates;
    std::vector<int> bufferSizes;
};

class ROUGHTRACK_SWIFT_IMMORTAL App
{
public:
    // The session
    std::string sessionName() const;
    std::vector<std::string> sessions() const;
    void openSession (const std::string& name);

    /** Empty if it worked, otherwise what went wrong. */
    std::string newSession (const std::string& name);

    /** Goes up when tracks, clips, plugins or the session change. */
    std::uint32_t revision() const;
    std::vector<TrackInfo> tracks() const;
    std::vector<ClipInfo> clips (int track) const;

    /** The loudest point in each of numPoints equal stretches of a take, 0 to 1. */
    std::vector<float> waveform (const std::string& file, std::int64_t offset, std::int64_t length, int numPoints) const;

    // Transport
    void play();
    void stop();

    /** Empty if it worked, otherwise why recording couldn't start. */
    std::string record();
    void returnToStart();
    void seek (std::int64_t position);

    Transport transport() const;
    std::int64_t position() const;
    double sampleRate() const;
    double tempo() const;
    std::int64_t sessionLength() const;

    // Editing. Positions and distances are in samples. Placing freely ignores the grid.
    std::vector<ClipInfo> previewDrag (int track, int clip, DragZone, std::int64_t distance, bool placeFreely) const;
    void commitDrag (int track, int clip, DragZone, std::int64_t distance, bool placeFreely);
    void splitClip (int track, int clip, std::int64_t position, bool placeFreely);
    void deleteClip (int track, int clip);
    void setClipLooping (int track, int clip, bool);
    void quantizeClip (int track, int clip, int gridTicks);

    /** The notes of a MIDI take that fall in a stretch of it, in samples. */
    std::vector<NoteInfo> midiNotes (int track, const std::string& file, std::int64_t offset, std::int64_t length) const;

    // Drums. Loading the library can take a moment the first time.
    std::vector<GrooveInfo> grooves() const;

    /** A groove's hits over some bars of a part, starting offsetBars into it, repeating as
        the part does.
    */
    std::vector<DrumHitInfo> grooveHits (const std::string& groove, int offsetBars, int bars) const;

    /** Empty if it worked, otherwise why not. The part starts in the bar position falls in. */
    std::string addPart (int track, const std::string& groove, std::int64_t position);
    void startGroovePreview (int track, const std::string& groove);
    void stopGroovePreview();
    bool isPreviewingGroove() const;

    std::vector<std::string> takes (int track) const;
    void addTakeAtPlayhead (int track, const std::string& file);

    /** Copies an audio file into the session and places it; track -1 makes a new track. */
    void importAudio (const std::string& file, int track, std::int64_t position);

    Snap snap() const;
    void setSnap (Snap);
    std::int64_t snapPosition (std::int64_t position, bool placeFreely) const;
    double samplesPerBeat() const;

    // The loop range (the cycle)
    bool cycleEnabled() const;
    std::int64_t cycleStart() const;
    std::int64_t cycleEnd() const;
    void setCycleEnabled (bool);
    void setCycleRange (std::int64_t start, std::int64_t end);
    void clearCycle();
    std::int64_t minimumCycleLength() const;

    // The mixer. Levels are linear gains, 1 being 0 dB.
    void setGain (int track, float);
    void setPan (int track, float);
    void setInverted (int track, bool);
    void setInput (int track, int firstInput, int numChannels);
    int inputChannelCount() const;

    float masterGain() const;
    void setMasterGain (float);
    void setTempo (double);
    bool clickEnabled() const;
    void setClickEnabled (bool);

    std::vector<ParameterInfo> channelParameters() const;
    float channelParameter (int track, int index) const;
    void setChannelParameter (int track, int index, float value);

    std::vector<ParameterInfo> auxParameters() const;
    float auxParameter (int index) const;
    void setAuxParameter (int index, float value);

    /** Each returns empty if it worked, otherwise what went wrong. */
    std::string loadAmp (int track, const std::string& file);
    void removeAmp (int track);
    std::string loadCabinet (int track, const std::string& file);
    void clearCabinet (int track);
    std::string ampFolder() const;

    // Plugins
    std::vector<PluginInfo> plugins (bool instruments) const;
    std::vector<InsertInfo> inserts (int track) const;

    /** Empty if loading started, otherwise why not. It finishes in the background. */
    std::string loadPlugin (int track, int slot, int libraryIndex);
    void removePlugin (int track, int slot);
    void setPluginBypassed (int track, int slot, bool);
    void setPluginBeforeAmp (int track, int slot, bool);
    void rescanPlugins();
    bool isScanningPlugins() const;

    /** Attaches a plugin's editor to an NSView. Returns a handle, or 0. The editor goes if
        its plugin does, and isEditorOpen() then turns false, so the window should close.
    */
    int openEditor (int track, int slot, void* parentView);
    bool isEditorOpen (int handle) const;
    EditorSize editorSize (int handle) const;
    void resizeEditor (int handle, int width, int height);
    void closeEditor (int handle);

    // Tracks
    /** Returns the new track, or -1. */
    int addTrack (TrackKind);

    /** Empty if it worked, otherwise why not. */
    std::string deleteTrack (int track);
    void moveTrack (int track, int newPosition);
    void renameTrack (int track, const std::string& name);

    void setMuted (int track, bool);
    void setSoloed (int track, bool);
    void setArmed (int track, bool);
    void setMonitoring (int track, bool);

    /** Levels rising and falling like a VU needle, 0 to 1 and beyond. */
    float trackLevel (int track) const;
    float masterLevel() const;

    // The tuner, read each frame while it shows
    void startTuner();
    void stopTuner();
    TunerInfo tuner() const;

    // Latency calibration. Empty if it started, otherwise why not.
    std::string startCalibration();
    bool isCalibrating() const;
    CalibrationInfo takeCalibrationResult();

    /** The calibrated round trip for the device as set up now, or -1 if it hasn't been. */
    double calibratedLatencyMs() const;

    // A keyboard's DAW controls
    std::string controllerName() const;
    bool controllerAutomatic() const;
    std::vector<std::string> midiInputNames() const;

    /** A port by name, or empty for none. */
    void chooseController (const std::string& portName);
    void chooseControllerAutomatically();
    int controllerBank() const;

    // Mixdown. Empty if it started, otherwise why not.
    std::string startMixdown (const std::string& path, bool stems);
    bool isMixingDown() const;
    double mixdownProgress() const;
    void cancelMixdown();
    MixdownInfo takeMixdownOutcome();
    std::string mixdownFolder() const;
    std::string nextStemsFolder() const;

    // Updates, off until releases have a home
    std::string version() const;
    bool updateCheckingAvailable() const;
    void checkForUpdates (bool manual);
    UpdateInfo takeUpdateOutcome();
    void skipUpdate (const std::string& version);
    bool checksForUpdatesAutomatically() const;
    void setChecksForUpdatesAutomatically (bool);

    // Undo
    bool canUndo() const;
    bool canRedo() const;
    std::string undoName() const;
    std::string redoName() const;
    void undo();
    void redo();

    // Plugins and messages
    bool isRestoringPlugins() const;
    std::vector<Message> takeMessages();

    // Audio device
    AudioDeviceInfo audioDevice() const;

    /** Empty if it worked, otherwise what went wrong. */
    std::string chooseAudioDevice (const std::string& name, double sampleRate, int bufferSize);
};

/** Starts JUCE and the studio. Call once, on the main thread, before app(). */
void startStudio();

/** Saves the session and closes the audio device. */
void stopStudio();

/** Null before startStudio() and after stopStudio(). */
App* app();

/** True if this is the first argument of a process launched to scan one plugin. */
bool isPluginScanChild (const char* firstArgument);

/** Scans one plugin in this process, writes the result file and returns the exit code. */
int runPluginScanChild (const char* format, const char* identifier, const char* resultFile);

} // namespace rt

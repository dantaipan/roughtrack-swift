#pragma once

#include "roughtrack/AudioEngine.h"
#include "roughtrack/ClipDrag.h"
#include "roughtrack/ControllerInput.h"
#include "roughtrack/Tuner.h"
#include "roughtrack/Updates.h"
#include "roughtrack/Grid.h"
#include "roughtrack/HostedEditor.h"
#include "roughtrack/PluginLibrary.h"
#include "roughtrack/Tone3000.h"

#include <juce_audio_devices/juce_audio_devices.h>
#include <juce_data_structures/juce_data_structures.h>
#include <juce_events/juce_events.h>

#include <atomic>
#include <deque>
#include <optional>
#include <thread>

namespace roughtrack
{

/** Where the studio keeps things. Tests point these at temporary folders. */
struct StudioPaths
{
    juce::File sessionsFolder;
    juce::File drumsFolder;
    juce::File settingsFile;
    juce::File pluginListFile;

    /** Run once for each plugin to scan it in its own process, with scanChildArgument. */
    juce::File scanExecutable;

    /** TONE3000, with the sign-in every app on the Mac shares. Off for tests, which
        mustn't touch it. */
    bool useTone3000 = false;

    /** The places the app uses: ~/Music/RoughTrack and Application Support, shared with the JUCE RoughTrack. */
    static StudioPaths forApp();
};

inline constexpr auto scanChildArgument = "--scan-plugin";

/** A line for the status area. */
struct StudioMessage
{
    juce::String text;
    bool isWarning = false;
};

/** Everything the app does apart from drawing: the audio device, sessions, plugins,
    undo and the transport. The UI reads it and asks it to do things, and never
    reaches past it to the engine to change anything.

    Everything here belongs to the message thread.
*/
class Studio final : private juce::ChangeListener,
                     private juce::Timer
{
public:
    explicit Studio (StudioPaths);
    ~Studio() override;

    /** Asks for microphone access, then opens the audio device and the last session. */
    void start();

    /** Opens the last session without any audio device, as tests do. */
    void startWithoutAudio();

    AudioEngine& getEngine() noexcept { return engine; }
    const AudioEngine& getEngine() const noexcept { return engine; }
    juce::AudioDeviceManager& getDeviceManager() noexcept { return deviceManager; }
    PluginLibrary& getPluginLibrary() noexcept { return *pluginLibrary; }

    /** Switches to an output device (using its own inputs when it has them), rate and
        buffer size, and remembers it as the one to return to.
    */
    juce::String chooseAudioDevice (const juce::String& outputName, double sampleRate, int bufferSize);

    //==============================================================================
    juce::File getCurrentSession() const { return currentSession; }

    /** The session folders in the sessions folder, by name. */
    juce::Array<juce::File> listSessions() const;

    /** Creates an empty session with this name and opens it. */
    juce::Result newSession (const juce::String& name);

    void openSession (const juce::File& directory);

    /** Writes session.xml if anything changed. Nothing is written while the transport runs. */
    void saveSession();

    //==============================================================================
    void play();
    void stop();
    juce::Result record();
    void returnToStart();

    /** Moves the playhead, while stopped. */
    void seek (juce::int64 position);

    //==============================================================================
    void setTrackMuted (int track, bool);
    void setTrackSoloed (int track, bool);
    void setTrackArmed (int track, bool);
    void setTrackMonitoring (int track, bool);

    void renameTrack (int track, const juce::String& name);

    /** Adds a track at the end, named like "Audio 2", and returns it, or -1 if it can't.
        A MIDI track starts with macOS's own instrument, so it plays straight away.
    */
    int addTrack (TrackType);

    /** Removes a track with its clips and plugins. Its takes stay in the session folder.
        Undo history refers to tracks by number, so it's cleared.
    */
    juce::Result deleteTrack (int track);
    void moveTrack (int track, int newPosition);

    //==============================================================================
    // The mixer. Continuous controls mark the session changed and the autosave writes it,
    // so dragging a fader doesn't write the file at every step. None of it is undoable.
    void setTrackGain (int track, float linearGain);
    void setTrackPan (int track, float pan);
    void setTrackInverted (int track, bool);
    void setTrackInput (int track, int firstInputChannel, int numChannels);
    void setMasterGain (float linearGain);
    void setTempo (double beatsPerMinute);
    void setClickEnabled (bool);
    void setChannelParameter (int track, ChannelParameter, float value);
    void setAuxParameter (AuxParameter, float value);

    /** How many input channels the device has open, for choosing a track's input. */
    int getNumInputChannels() const;

    /** A source says where a downloaded file came from; a file picked from disk has none. */
    juce::Result loadAmp (int track, const juce::File& capture, const FileSource& source = {});
    void removeAmp (int track);
    juce::Result loadCabinet (int track, const juce::File& impulse, const FileSource& source = {});
    void clearCabinet (int track);

    /** Null when TONE3000 is off (tests). */
    Tone3000* getTone3000() noexcept { return tone3000.get(); }

    /** Where captures and impulses were last loaded from. */
    juce::File getAmpFolder() const;

    //==============================================================================
    /** Loads the library's plugin at this index into a slot: an instrument into the
        instrument slot, an effect into the others. It loads in the background.
    */
    juce::Result loadPlugin (int track, int slot, int libraryIndex);
    void removePlugin (int track, int slot);
    void setPluginBypassed (int track, int slot, bool);
    void setPluginBeforeAmp (int track, int slot, bool);

    /** Scans for plugins again, replacing the list. */
    void rescanPlugins();

    //==============================================================================
    /** Opens a plugin's editor inside a view, and returns a handle, or 0 if it can't. */
    int openEditor (int track, int slot, void* parentView);
    bool isEditorOpen (int handle) const { return editors.count (handle) > 0; }
    juce::Rectangle<int> getEditorSize (int handle) const;
    void resizeEditor (int handle, int width, int height);
    bool isEditorResizable (int handle) const;

    /** Closes an editor and saves the plugins' settings, which may have changed in it. */
    void closeEditor (int handle);

    //==============================================================================
    /** The rate the timeline counts in: the device's, or 48 kHz without one. */
    double getTimelineRate() const;
    double getSamplesPerBeat() const;

    /** A position in samples in a track's own units: ticks on a MIDI track. */
    juce::int64 toClipUnits (int track, juce::int64 samples) const;
    juce::int64 toSamples (int track, juce::int64 clipUnits) const;

    SnapGrid getSnap() const noexcept { return snap; }
    void setSnap (SnapGrid);

    /** A timeline position on the grid, or left alone when placing freely. */
    juce::int64 snapPosition (juce::int64 samples, bool placeFreely) const;

    //==============================================================================
    /** Replaces a track's clips as one undoable step. */
    void applyClipEdit (int track, const ClipList&, const juce::String& editName);

    /** Where a drag would put the track's clips, without changing anything. The distance
        is in samples; placing freely ignores the grid, as Command does.
    */
    ClipList previewDrag (int track, int clip, DragZone, juce::int64 distance, bool placeFreely) const;
    void commitDrag (int track, int clip, DragZone, juce::int64 distance, bool placeFreely);

    void splitClip (int track, int clip, juce::int64 position, bool placeFreely);
    void deleteClip (int track, int clip);
    void setClipLooping (int track, int clip, bool shouldLoop);
    void quantizeClip (int track, int clip, int gridTicks);

    //==============================================================================
    // Drum parts are in whole bars. The clip calls above work on a drum track's parts too.
    double getSamplesPerBar() const;

    /** Replaces a drum track's parts as one undoable step. */
    void applyDrumEdit (int track, const DrumPartList&, const juce::String& editName);

    DrumPartList previewPartDrag (int track, int part, DragZone, juce::int64 distance) const;

    /** Puts a groove on a drum track, starting in the bar a position falls in. */
    juce::Result addPart (int track, const juce::String& grooveId, juce::int64 position);

    /** Plays a groove through a drum track until stopped, lined up with the song if it's running. */
    void startGroovePreview (int track, const juce::String& grooveId);
    void stopGroovePreview();

    /** The session's recordings a track could use: WAV takes, or MIDI ones on a MIDI track. */
    juce::Array<juce::File> findTakes (int track) const;

    /** Puts a take on a track at the playhead. */
    void addTakeAtPlayhead (int track, const juce::File&);

    //==============================================================================
    /** Turned on with nowhere to go round, the loop takes the four bars from the playhead's bar. */
    void setCycleEnabled (bool);
    void setCycleRange (juce::Range<juce::int64>);
    void clearCycle();

    //==============================================================================
    /** Copies an audio file into the session as a WAV at the session's rate, then places it
        on a track at a position in samples. A track of -1, or one that isn't for audio,
        means a new audio track named after the file. The copying happens in the background.
    */
    void importAudio (const juce::File&, int track, juce::int64 position);

    /** importAudio() done straight away on this thread, for tests. */
    juce::Result importAudioNow (const juce::File&, int track, juce::int64 position);

    /** Reads any audio file JUCE can, folds it to mono or stereo, converts it to a rate and
        writes it as a 24-bit WAV.
    */
    static juce::Result convertAudioFile (const juce::File& source, const juce::File& destination, double sampleRate);

    //==============================================================================
    // The tuner listens to the armed audio track's input, or the first audio track's.
    void startTuner();
    void stopTuner();
    bool isTunerRunning() const noexcept { return tunerDetector != nullptr; }

    struct TunerDisplay
    {
        bool hasNote = false;
        juce::String note;
        double cents = 0.0;
        juce::String source;
    };

    TunerDisplay getTunerDisplay() const;

    //==============================================================================
    /** Plays test sweeps out of output 1 and finds them on input 1, joined by a cable. */
    juce::Result startCalibration();
    bool isCalibrating() const noexcept { return calibrating; }

    /** How the last calibration went, once, after it finishes. */
    std::optional<LatencyCalibrator::Result> takeCalibrationResult();

    /** The calibrated latency for the device as it's set up now, or -1 if it hasn't been. */
    int getCalibratedLatency() const;

    //==============================================================================
    // A keyboard's DAW controls. With no choice made, the port named like one is used.
    juce::String getControllerName() const { return controllerName; }
    bool isControllerAutomatic() const;

    /** A MIDI input by name, or empty for none. */
    void chooseController (const juce::String& portName);
    void chooseControllerAutomatically();
    juce::StringArray getMidiInputNames() const;
    int getControllerBank() const noexcept { return controllerBank; }

    /** Carries out a command as if the controller's button had been pressed. */
    void runControlCommand (ControlEvent);

    /** What the MIDI inputs reach: the controller sorting, then the engine. For tests. */
    ControllerInput& getControllerInput() noexcept { return controllerInput; }

    //==============================================================================
    /** Mixes the session down to a WAV, or exports a stem per track into a folder, on a
        background thread. Nothing else plays or changes meanwhile.
    */
    juce::Result startMixdown (const juce::File& fileOrFolder, bool stems);
    bool isMixingDown() const noexcept { return mixdownRunning.load() || mixdownThread.joinable(); }
    double getMixdownProgress() const noexcept { return mixdownProgress.load(); }
    void cancelMixdown() noexcept { mixdownCancelled = true; }

    struct MixdownOutcome
    {
        juce::File file;
        bool stems = false;
        AudioEngine::BounceResult result;
        int numStems = 0;
        double seconds = 0.0;
    };

    /** The finished mixdown, once. */
    std::optional<MixdownOutcome> takeMixdownOutcome();

    /** Where the playhead shows. A mixdown runs the engine's position through the song, so
        while one runs this stays where the playhead was, and the timeline doesn't chase it.
    */
    juce::int64 getDisplayPosition() const noexcept { return isMixingDown() ? mixdownReturnPosition : engine.getPosition(); }

    juce::File getMixdownFolder() const;
    juce::File getNextStemsFolder() const;

    //==============================================================================
    /** Asks for the latest release in the background, if checking is set up. */
    void checkForUpdates (bool isManual);
    bool isCheckingForUpdates() const noexcept { return updateThread.joinable(); }

    struct UpdateOutcome
    {
        std::optional<updates::Release> release;
        juce::String error;
        bool isManual = false;
    };

    std::optional<UpdateOutcome> takeUpdateOutcome();
    void skipUpdate (const juce::String& version);

    /** Whether to check once a day by itself, as the JUCE RoughTrack does (the same setting). */
    bool checksForUpdatesAutomatically() const;
    void setChecksForUpdatesAutomatically (bool);

    bool canUndo() const { return undoManager.canUndo(); }
    bool canRedo() const { return undoManager.canRedo(); }
    juce::String getUndoName() const { return undoManager.getUndoDescription(); }
    juce::String getRedoName() const { return undoManager.getRedoDescription(); }
    void undo();
    void redo();

    //==============================================================================
    /** True while the session's plugins are still loading in the background. */
    bool isRestoringPlugins() const noexcept { return numInsertsRestoring > 0; }
    void startPluginScan();
    void saveInserts();

    //==============================================================================
    /** Goes up whenever tracks, clips, plugins or the session change, so the UI knows
        to read them again.
    */
    juce::uint32 getRevision() const noexcept { return revision; }

    /** Messages posted since the last call, oldest first. */
    std::vector<StudioMessage> takeMessages();
    void postMessage (const juce::String&, bool isWarning = false);

    /** Called by the timer, and by tests that don't run a message loop. */
    void tick();

private:
    void changeListenerCallback (juce::ChangeBroadcaster*) override;
    void timerCallback() override { tick(); }

    void startAudio();
    void useInterfaceInputs();
    void deviceChanged();
    void restoreChosenAudioDevice();
    juce::String deviceDescription() const;
    juce::String latencyKey() const;

    void loadCurrentSession();

    /** Editors must close before their plugins go. A slot of -1 means all the track's,
        and a track of -1 means every editor.
    */
    void closeEditors (int track, int slot = -1);
    void loadDefaultInstrument (int track);
    void enableMidiInputs();
    void handleControlEvents();
    void stripCommand (ControlEvent);
    void moveArm (int direction);
    std::vector<bool> armedByLane() const;
    void showControllerLights();
    void updateTuner (double secondsSinceLast);
    void finishMixdown();
    bool isDrums (int track) const;
    juce::String nextTrackName (const juce::String& baseName) const;
    bool canEdit();
    juce::File importDestinationFor (const juce::File& source) const;
    double importRate() const;
    juce::Result placeImportedTake (const juce::File& take, int track, juce::int64 position, const juce::String& trackName);
    void recordingFinished();
    void changed();

    juce::File insertsFile() const;
    void restoreInserts();
    void loadInsert (int track, int slot, const SavedInsert&);
    bool canChangeInserts();

    const StudioPaths paths;
    std::unique_ptr<juce::PropertiesFile> settings;
    std::unique_ptr<PluginLibrary> pluginLibrary;

    AudioEngine engine;
    juce::AudioDeviceManager deviceManager;
    bool audioStarted = false;

    juce::File currentSession;
    bool sessionLoaded = false;
    juce::String lastSavedSession;
    int autosaveCountdown = 0;

    juce::UndoManager undoManager;
    std::array<ClipList, maxTracks> clipsBeforeRecording;
    bool recordingInProgress = false;

    int numInsertsRestoring = 0;
    bool insertsNeedKeeping = false;

    SnapGrid snap = SnapGrid::bar;
    std::map<int, std::unique_ptr<HostedEditor>> editors;
    int nextEditorHandle = 1;
    juce::ThreadPool importThread { juce::ThreadPoolOptions().withNumberOfThreads (1).withThreadName ("Import") };

    juce::MidiDeviceListConnection midiDevices;
    juce::StringArray midiInputs;

    // Commands arrive on the MIDI thread and are carried out in tick().
    juce::SpinLock controlLock;
    std::vector<ControlEvent> pendingControls;
    ControllerInput controllerInput {
        [this] (juce::MidiInput* source, const juce::MidiMessage& message) { engine.handleIncomingMidiMessage (source, message); },
        [this] (ControlEvent event)
        {
            const juce::SpinLock::ScopedLockType scope (controlLock);
            pendingControls.push_back (event);
        }
    };
    juce::String controllerName;
    std::unique_ptr<juce::MidiOutput> controllerOutput;
    std::optional<std::array<bool, 128>> litNotes;
    int controllerBank = 0;

    std::unique_ptr<PitchDetector> tunerDetector;
    std::vector<float> tunerHistory, tunerArriving;
    int tunerSamplesSinceAnalysis = 0;
    std::vector<double> tunerRecentCents;
    int tunerNote = -1;
    double tunerCents = 0.0, tunerSecondsSinceNote = 0.0;
    juce::String tunerSource;

    bool calibrating = false;
    std::optional<LatencyCalibrator::Result> calibrationResult;

    std::thread mixdownThread;
    std::atomic<bool> mixdownRunning { false }, mixdownCancelled { false };
    std::atomic<double> mixdownProgress { 0.0 };
    juce::int64 mixdownReturnPosition = 0;
    MixdownOutcome mixdownWork;
    std::optional<MixdownOutcome> mixdownOutcome;

    bool automaticUpdateCheckDone = false;
    std::thread updateThread;
    std::atomic<bool> updateRunning { false };
    UpdateOutcome updateWork;
    std::optional<UpdateOutcome> updateOutcome;

    juce::String lastAudioRestoreFrom, lastRateWarning;
    juce::uint32 revision = 1;
    std::deque<StudioMessage> messages;

    // Last, so it goes first: its replies call back into everything above.
    std::unique_ptr<Tone3000> tone3000;

    JUCE_DECLARE_WEAK_REFERENCEABLE (Studio)
};

} // namespace roughtrack

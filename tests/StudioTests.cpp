#include "TestHelpers.h"

#include "RoughTrackCore.h"
#include "roughtrack/Studio.h"

#include <catch2/catch_test_macros.hpp>

using namespace roughtrack;

namespace
{

StudioPaths pathsIn (const juce::File& root)
{
    StudioPaths paths;
    paths.sessionsFolder = root.getChildFile ("Sessions");
    paths.drumsFolder = root.getChildFile ("Drums");
    paths.settingsFile = root.getChildFile ("test.settings");
    paths.pluginListFile = root.getChildFile ("test.plugins.xml");
    return paths;
}

juce::File writeTake (const juce::File& folder, int numSamples)
{
    juce::AudioBuffer<float> buffer (1, numSamples);

    for (int i = 0; i < numSamples; ++i)
        buffer.setSample (0, i, 0.5f * std::sin ((float) i * 0.05f));

    folder.createDirectory();
    const auto file = folder.getChildFile ("take.wav");
    test::writeWav (file, buffer, 48000.0);
    return file;
}

} // namespace

TEST_CASE ("A new studio starts an empty session with one audio track")
{
    const juce::ScopedJuceInitialiser_GUI juce;
    test::TempDirectory temp;

    Studio studio (pathsIn (temp.directory));
    studio.startWithoutAudio();

    REQUIRE (studio.getCurrentSession() == temp.directory.getChildFile ("Sessions/Session"));
    REQUIRE (studio.getEngine().getTrackOrder().size() == 1);
    REQUIRE (studio.getEngine().getTrackName (studio.getEngine().getTrackOrder()[0]) == "Audio 1");
}

TEST_CASE ("A session saved by the studio opens again with its tracks and clips")
{
    const juce::ScopedJuceInitialiser_GUI juce;
    test::TempDirectory temp;
    juce::File take;

    {
        Studio studio (pathsIn (temp.directory));
        studio.startWithoutAudio();
        REQUIRE (studio.newSession ("Song").wasOk());

        take = writeTake (studio.getCurrentSession(), 48000);
        auto& engine = studio.getEngine();
        const auto track = engine.getTrackOrder()[0];
        REQUIRE (engine.loadTake (track, take, 1000));
        engine.setTrackName (track, "Guitar");
        studio.setTrackMuted (track, true);
        studio.saveSession();
    }

    Studio reopened (pathsIn (temp.directory));
    reopened.startWithoutAudio();

    const auto& engine = reopened.getEngine();
    REQUIRE (reopened.getCurrentSession().getFileName() == "Song");
    REQUIRE (engine.getTrackOrder().size() == 1);

    const auto track = engine.getTrackOrder()[0];
    REQUIRE (engine.getTrackName (track) == "Guitar");
    REQUIRE (engine.getTrackSettings (track).muted);
    REQUIRE (engine.getClips (track).size() == 1);
    REQUIRE (engine.getClips (track)[0].timelineStart == 1000);
    REQUIRE (engine.getClips (track)[0].file == take);
}

TEST_CASE ("A clip edit through the studio can be undone and redone")
{
    const juce::ScopedJuceInitialiser_GUI juce;
    test::TempDirectory temp;

    Studio studio (pathsIn (temp.directory));
    studio.startWithoutAudio();

    auto& engine = studio.getEngine();
    const auto track = engine.getTrackOrder()[0];
    REQUIRE (engine.loadTake (track, writeTake (studio.getCurrentSession(), 48000), 0));

    const auto revisionBefore = studio.getRevision();
    studio.applyClipEdit (track, moveClip (engine.getClips (track), 0, 5000), "Move Clip");

    REQUIRE (engine.getClips (track)[0].timelineStart == 5000);
    REQUIRE (studio.getRevision() != revisionBefore);
    REQUIRE (studio.getUndoName() == "Move Clip");

    studio.undo();
    REQUIRE (engine.getClips (track)[0].timelineStart == 0);

    studio.redo();
    REQUIRE (engine.getClips (track)[0].timelineStart == 5000);
}

TEST_CASE ("A session name that's taken or empty isn't created")
{
    const juce::ScopedJuceInitialiser_GUI juce;
    test::TempDirectory temp;

    Studio studio (pathsIn (temp.directory));
    studio.startWithoutAudio();

    REQUIRE (studio.newSession ("Song").wasOk());
    REQUIRE (studio.newSession ("Song").failed());
    REQUIRE (studio.newSession ("   ").failed());
    // The session open at the start is there too.
    REQUIRE (studio.listSessions().size() == 2);
    REQUIRE (studio.listSessions().contains (temp.directory.getChildFile ("Sessions/Song")));
}

TEST_CASE ("The playhead only moves by seeking while stopped")
{
    const juce::ScopedJuceInitialiser_GUI juce;
    test::TempDirectory temp;

    Studio studio (pathsIn (temp.directory));
    studio.startWithoutAudio();

    studio.seek (12345);
    REQUIRE (studio.getEngine().getPosition() == 12345);

    studio.seek (-10);
    REQUIRE (studio.getEngine().getPosition() == 0);
}

//==============================================================================
namespace
{

/** A stereo file with a click on the left at a known time and silence on the right. */
juce::File writeStereoTake (const juce::File& file, double rate, int numSamples, int clickAt)
{
    juce::AudioBuffer<float> buffer (2, numSamples);
    buffer.clear();
    buffer.setSample (0, clickAt, 0.8f);
    file.getParentDirectory().createDirectory();
    test::writeWav (file, buffer, rate);
    return file;
}

} // namespace

TEST_CASE ("An imported file is converted to the session's rate, kept stereo and placed")
{
    const juce::ScopedJuceInitialiser_GUI juce;
    test::TempDirectory temp;

    Studio studio (pathsIn (temp.directory));
    studio.startWithoutAudio();

    // One second at 44.1 kHz, with a click half way.
    const auto source = writeStereoTake (temp.directory.getChildFile ("Outside/song.wav"), 44100.0, 44100, 22050);
    const auto track = studio.getEngine().getTrackOrder()[0];

    REQUIRE (studio.importAudioNow (source, track, 96000).wasOk());

    const auto& clips = studio.getEngine().getClips (track);
    REQUIRE (clips.size() == 1);
    CHECK (clips[0].timelineStart == 96000);
    CHECK (clips[0].file.getParentDirectory() == studio.getCurrentSession());
    CHECK (clips[0].file != source);
    CHECK (studio.getUndoName() == "Import Audio");

    // With no device the timeline runs at 48 kHz, and the first take sets the session's rate.
    CHECK (studio.getEngine().getSessionSampleRate() == 48000.0);

    const auto reader = test::openReader (clips[0].file);
    REQUIRE (reader != nullptr);
    CHECK (reader->sampleRate == 48000.0);
    CHECK (reader->numChannels == 2);
    CHECK (std::abs (reader->lengthInSamples - 48000) <= 1);
    CHECK (clips[0].length == reader->lengthInSamples);

    // The click lands at half a second, in time, on the left only.
    const auto converted = test::readAll (clips[0].file);
    CHECK (std::abs (test::findPeak (converted, 0) - 24000) <= 2);
    CHECK (converted.getMagnitude (1, 0, converted.getNumSamples()) < 0.001f);

    // The original is left alone.
    CHECK (source.existsAsFile());
}

TEST_CASE ("Importing onto no track makes a new one named after the file")
{
    const juce::ScopedJuceInitialiser_GUI juce;
    test::TempDirectory temp;

    Studio studio (pathsIn (temp.directory));
    studio.startWithoutAudio();

    const auto source = writeStereoTake (temp.directory.getChildFile ("Outside/Bass DI.wav"), 48000.0, 4800, 10);
    REQUIRE (studio.importAudioNow (source, -1, 0).wasOk());

    const auto& engine = studio.getEngine();
    REQUIRE (engine.getTrackOrder().size() == 2);

    const auto track = engine.getTrackOrder()[1];
    CHECK (engine.getTrackName (track) == "Bass DI");
    CHECK (engine.getClips (track).size() == 1);

    // A second one with the same name gets its own file and track.
    REQUIRE (studio.importAudioNow (source, -1, 0).wasOk());
    REQUIRE (engine.getTrackOrder().size() == 3);
    CHECK (engine.getTrackName (engine.getTrackOrder()[2]) == "Bass DI 2");
    CHECK (engine.getClips (engine.getTrackOrder()[2])[0].file != engine.getClips (track)[0].file);
}

TEST_CASE ("A file that isn't audio leaves the session alone and says so")
{
    const juce::ScopedJuceInitialiser_GUI juce;
    test::TempDirectory temp;

    Studio studio (pathsIn (temp.directory));
    studio.startWithoutAudio();
    studio.takeMessages();

    const auto source = temp.directory.getChildFile ("notes.txt");
    REQUIRE (source.replaceWithText ("not audio"));

    CHECK (studio.importAudioNow (source, -1, 0).failed());
    CHECK (studio.getEngine().getTrackOrder().size() == 1);
    CHECK (studio.getCurrentSession().findChildFiles (juce::File::findFiles, false, "*.wav").isEmpty());

    const auto messages = studio.takeMessages();
    REQUIRE (! messages.empty());
    CHECK (messages.back().isWarning);
}

TEST_CASE ("New tracks are numbered, and the last track can't be deleted")
{
    const juce::ScopedJuceInitialiser_GUI juce;
    test::TempDirectory temp;

    Studio studio (pathsIn (temp.directory));
    studio.startWithoutAudio();

    auto& engine = studio.getEngine();
    const auto first = engine.getTrackOrder()[0];
    const auto audio = studio.addTrack (TrackType::audio);
    const auto midi = studio.addTrack (TrackType::midi);
    const auto midi2 = studio.addTrack (TrackType::midi);

    CHECK (engine.getTrackName (audio) == "Audio 2");
    CHECK (engine.getTrackName (midi) == "MIDI");
    CHECK (engine.getTrackName (midi2) == "MIDI 2");
    CHECK (engine.getTrackType (midi) == TrackType::midi);

    studio.renameTrack (audio, "  Guitar  ");
    CHECK (engine.getTrackName (audio) == "Guitar");

    studio.moveTrack (midi2, 0);
    CHECK (engine.getTrackOrder()[0] == midi2);

    // Deleting clears undo, because undo steps name tracks by number.
    REQUIRE (engine.loadTake (first, writeTake (studio.getCurrentSession(), 4800), 0));
    studio.applyClipEdit (first, moveClip (engine.getClips (first), 0, 100), "Move Clip");
    REQUIRE (studio.canUndo());

    CHECK (studio.deleteTrack (audio).wasOk());
    CHECK_FALSE (studio.canUndo());

    CHECK (studio.deleteTrack (midi).wasOk());
    CHECK (studio.deleteTrack (midi2).wasOk());
    CHECK (studio.deleteTrack (first).failed());
    CHECK (engine.getTrackOrder().size() == 1);
}

TEST_CASE ("Snap and the loop are kept with the session")
{
    const juce::ScopedJuceInitialiser_GUI juce;
    test::TempDirectory temp;

    {
        Studio studio (pathsIn (temp.directory));
        studio.startWithoutAudio();
        studio.setSnap (SnapGrid::sixteenth);
        studio.setCycleRange ({ 96000, 192000 });
        studio.saveSession();
    }

    Studio reopened (pathsIn (temp.directory));
    reopened.startWithoutAudio();

    CHECK (reopened.getSnap() == SnapGrid::sixteenth);
    CHECK (reopened.getEngine().getCycleRange() == juce::Range<juce::int64> (96000, 192000));
    CHECK (reopened.getEngine().isCycleEnabled());

    reopened.clearCycle();
    CHECK (reopened.getEngine().getCycleRange().isEmpty());
    CHECK_FALSE (reopened.getEngine().isCycleEnabled());
}

TEST_CASE ("Turning the loop on with no range takes four bars from the playhead's bar")
{
    const juce::ScopedJuceInitialiser_GUI juce;
    test::TempDirectory temp;

    Studio studio (pathsIn (temp.directory));
    studio.startWithoutAudio();

    // 120 bpm at 48 kHz: a bar is 96000 samples. The playhead is part way into bar 3.
    studio.seek (2 * 96000 + 5000);
    studio.setCycleEnabled (true);

    CHECK (studio.getEngine().getCycleRange() == juce::Range<juce::int64> (2 * 96000, 6 * 96000));
    CHECK (studio.getEngine().isCycleEnabled());
}

TEST_CASE ("Drags, splits and deletes through the studio follow the snap and undo as one step")
{
    const juce::ScopedJuceInitialiser_GUI juce;
    test::TempDirectory temp;

    Studio studio (pathsIn (temp.directory));
    studio.startWithoutAudio();

    auto& engine = studio.getEngine();
    const auto track = engine.getTrackOrder()[0];
    REQUIRE (engine.loadTake (track, writeTake (studio.getCurrentSession(), 192000), 1000));

    // A preview changes nothing; with Bar snap the start lands on bar 2.
    studio.setSnap (SnapGrid::bar);
    const auto preview = studio.previewDrag (track, 0, DragZone::body, 90000, false);
    CHECK (preview[0].timelineStart == 96000);
    CHECK (engine.getClips (track)[0].timelineStart == 1000);

    studio.commitDrag (track, 0, DragZone::body, 90000, false);
    CHECK (engine.getClips (track)[0].timelineStart == 96000);
    CHECK (studio.getUndoName() == "Move Clip");

    // Placing freely ignores the grid.
    CHECK (studio.previewDrag (track, 0, DragZone::body, 1234, true)[0].timelineStart == 97234);

    // A split near beat 3 of bar 2 lands on bar 3 with Bar snap.
    studio.splitClip (track, 0, 96000 + 90000, false);
    REQUIRE (engine.getClips (track).size() == 2);
    CHECK (engine.getClips (track)[1].timelineStart == 192000);
    CHECK (studio.getUndoName() == "Split Clip");

    studio.deleteClip (track, 1);
    CHECK (engine.getClips (track).size() == 1);
    CHECK (studio.getUndoName() == "Delete Clip");

    studio.undo();
    CHECK (engine.getClips (track).size() == 2);

    studio.setClipLooping (track, 0, true);
    CHECK (engine.getClips (track)[0].loopsToNext);
    CHECK (studio.getUndoName() == "Loop Until Next Part");
}

//==============================================================================
TEST_CASE ("Mixer settings, tempo and click are kept with the session")
{
    const juce::ScopedJuceInitialiser_GUI juce;
    test::TempDirectory temp;
    int track = -1;

    {
        Studio studio (pathsIn (temp.directory));
        studio.startWithoutAudio();
        track = studio.getEngine().getTrackOrder()[0];

        studio.setTrackGain (track, 0.5f);
        studio.setTrackPan (track, -0.25f);
        studio.setTrackInverted (track, true);
        studio.setTrackInput (track, 1, 2);
        studio.setMasterGain (0.8f);
        studio.setTempo (96.0);
        studio.setClickEnabled (true);
        studio.saveSession();
    }

    Studio reopened (pathsIn (temp.directory));
    reopened.startWithoutAudio();

    const auto& engine = reopened.getEngine();
    const auto settings = engine.getTrackSettings (track);
    CHECK (settings.gain == 0.5f);
    CHECK (settings.pan == -0.25f);
    CHECK (settings.inverted);
    CHECK (settings.firstInput == 1);
    CHECK (settings.inputChannels == 2);
    CHECK (engine.getMasterGain() == 0.8f);
    CHECK (engine.getTempo() == 96.0);
    CHECK (engine.isClickEnabled());
}

TEST_CASE ("Out-of-range mixer values are held to what the controls allow")
{
    const juce::ScopedJuceInitialiser_GUI juce;
    test::TempDirectory temp;

    Studio studio (pathsIn (temp.directory));
    studio.startWithoutAudio();
    const auto track = studio.getEngine().getTrackOrder()[0];

    studio.setTrackPan (track, 5.0f);
    studio.setTempo (1000.0);
    studio.setChannelParameter (track, ChannelParameter::compressorRatio, 1.0e6f);

    CHECK (studio.getEngine().getTrackSettings (track).pan == 1.0f);
    CHECK (studio.getEngine().getTempo() == 300.0);
    CHECK (studio.getEngine().getChannel (track).getParameter (ChannelParameter::compressorRatio)
           == getParameterInfo (ChannelParameter::compressorRatio).maximum);
}

TEST_CASE ("Channel and effects settings are kept with the session")
{
    const juce::ScopedJuceInitialiser_GUI juce;
    test::TempDirectory temp;
    int track = -1;

    {
        Studio studio (pathsIn (temp.directory));
        studio.startWithoutAudio();
        track = studio.getEngine().getTrackOrder()[0];

        studio.setChannelParameter (track, ChannelParameter::eqEnabled, 1.0f);
        studio.setChannelParameter (track, ChannelParameter::lowGain, 3.0f);
        studio.setChannelParameter (track, ChannelParameter::sendReverb, 0.4f);
        studio.setAuxParameter (AuxParameter::reverbSize, 0.7f);
        studio.saveSession();
    }

    Studio reopened (pathsIn (temp.directory));
    reopened.startWithoutAudio();

    const auto& channel = reopened.getEngine().getChannel (track);
    CHECK (channel.getParameter (ChannelParameter::eqEnabled) == 1.0f);
    CHECK (channel.getParameter (ChannelParameter::lowGain) == 3.0f);
    CHECK (channel.getParameter (ChannelParameter::sendReverb) == 0.4f);
    CHECK (reopened.getEngine().getAux().getParameter (AuxParameter::reverbSize) == 0.7f);
}

TEST_CASE ("A capture and a cabinet load through the studio, are saved, and clear")
{
    const juce::ScopedJuceInitialiser_GUI juce;
    test::TempDirectory temp;
    const juce::File examples (ROUGHTRACK_NAM_EXAMPLES);
    const auto capture = examples.getChildFile ("wavenet.nam");

    juce::AudioBuffer<float> impulse (1, 480);
    impulse.clear();
    impulse.setSample (0, 0, 1.0f);
    const auto cabinet = temp.directory.getChildFile ("IRs/cab.wav");
    cabinet.getParentDirectory().createDirectory();
    test::writeWav (cabinet, impulse, 48000.0);

    int track = -1;

    {
        Studio studio (pathsIn (temp.directory));
        studio.startWithoutAudio();
        track = studio.getEngine().getTrackOrder()[0];

        REQUIRE (studio.loadAmp (track, capture).wasOk());
        REQUIRE (studio.loadCabinet (track, cabinet).wasOk());
        CHECK (studio.getAmpFolder() == cabinet.getParentDirectory());

        // Something that isn't a capture says why and leaves the amp alone. (A WAV would
        // load: NAM runs an impulse response as a linear model.)
        const auto notes = temp.directory.getChildFile ("notes.nam");
        REQUIRE (notes.replaceWithText ("not a capture"));
        CHECK (studio.loadAmp (track, notes).failed());
        CHECK (studio.getEngine().getChannel (track).getAmpFile() == capture);
        studio.saveSession();
    }

    Studio reopened (pathsIn (temp.directory));
    reopened.startWithoutAudio();

    auto& channel = reopened.getEngine().getChannel (track);
    CHECK (channel.hasAmp());
    CHECK (channel.getAmpFile() == capture);
    CHECK (channel.getCabinetFile() == cabinet);

    reopened.removeAmp (track);
    reopened.clearCabinet (track);
    CHECK_FALSE (channel.hasAmp());
    CHECK (channel.getCabinetFile() == juce::File());
}

TEST_CASE ("A plugin slot that isn't in the list, or an editor for an empty slot, is refused")
{
    const juce::ScopedJuceInitialiser_GUI juce;
    test::TempDirectory temp;

    Studio studio (pathsIn (temp.directory));
    studio.startWithoutAudio();
    const auto track = studio.getEngine().getTrackOrder()[0];

    CHECK (studio.loadPlugin (track, 0, 0).failed());
    CHECK (studio.openEditor (track, 0, nullptr) == 0);
    CHECK_FALSE (studio.isEditorOpen (1));
}

//==============================================================================
TEST_CASE ("Grooves are added, dragged, split, looped and deleted on a drum track, each undoable")
{
    const juce::ScopedJuceInitialiser_GUI juce;
    test::TempDirectory temp;
    test::writeTestDrums (temp.directory.getChildFile ("Drums"));
    int drums = -1;

    {
        Studio studio (pathsIn (temp.directory));
        studio.startWithoutAudio();
        auto& engine = studio.getEngine();

        drums = studio.addTrack (TrackType::drums);
        REQUIRE (drums >= 0);
        REQUIRE (engine.getTrackName (drums) == "Drums");
        REQUIRE (engine.getGrooves().getGrooves().size() == 3);

        // At 120 BPM and 48 kHz a bar is 96000 samples; a position in bar 2 starts the part there.
        const auto bar = studio.getSamplesPerBar();
        REQUIRE (bar == 96000.0);
        REQUIRE (studio.addPart (drums, "beat", 2 * 96000 + 5000).wasOk());
        REQUIRE (engine.getDrumParts (drums).size() == 1);
        CHECK (engine.getDrumParts (drums)[0] == DrumPart { "beat", 2, 2, 0 });
        CHECK (studio.getUndoName() == "Add Groove");

        REQUIRE (studio.addPart (drums, "fill", 6 * 96000).wasOk());
        CHECK (studio.getUndoName() == "Add Fill");
        CHECK (studio.addPart (drums, "nothing", 0).failed());
        CHECK (studio.addPart (engine.getTrackOrder()[0], "beat", 0).failed());

        // Drags move by whole bars, rounding, and a preview changes nothing.
        CHECK (studio.previewPartDrag (drums, 0, DragZone::body, 150000)[0].startBar == 4);
        CHECK (engine.getDrumParts (drums)[0].startBar == 2);
        studio.commitDrag (drums, 0, DragZone::body, 150000, false);
        CHECK (engine.getDrumParts (drums)[0].startBar == 4);
        CHECK (studio.getUndoName() == "Move Part");

        // Not before the first bar.
        studio.commitDrag (drums, 0, DragZone::body, -10 * 96000, false);
        CHECK (engine.getDrumParts (drums)[0].startBar == 0);
        studio.undo();
        CHECK (engine.getDrumParts (drums)[0].startBar == 4);

        studio.commitDrag (drums, 0, DragZone::end, 96000, false);
        CHECK (engine.getDrumParts (drums)[0].bars == 3);
        CHECK (studio.getUndoName() == "Trim Part");

        studio.commitDrag (drums, 0, DragZone::start, 96000, false);
        CHECK (engine.getDrumParts (drums)[0] == DrumPart { "beat", 5, 2, 1 });

        // The clip calls work on parts too.
        studio.splitClip (drums, 0, 6 * 96000 + 1000, false);
        REQUIRE (engine.getDrumParts (drums).size() == 3);
        CHECK (studio.getUndoName() == "Split Part");

        studio.setClipLooping (drums, 1, true);
        CHECK (engine.getDrumParts (drums)[1].loopsToNext);
        CHECK (studio.getUndoName() == "Loop Until Next Part");

        studio.deleteClip (drums, 0);
        CHECK (engine.getDrumParts (drums).size() == 2);
        CHECK (studio.getUndoName() == "Delete Part");

        studio.undo();
        CHECK (engine.getDrumParts (drums).size() == 3);
        studio.redo();
        CHECK (engine.getDrumParts (drums).size() == 2);
        studio.saveSession();
    }

    Studio reopened (pathsIn (temp.directory));
    reopened.startWithoutAudio();
    const auto& parts = reopened.getEngine().getDrumParts (drums);
    REQUIRE (parts.size() == 2);
    CHECK (parts[0].loopsToNext);
}

TEST_CASE ("Drum edits and previews wait for the transport to stop")
{
    const juce::ScopedJuceInitialiser_GUI juce;
    test::TempDirectory temp;
    test::writeTestDrums (temp.directory.getChildFile ("Drums"));

    Studio studio (pathsIn (temp.directory));
    studio.startWithoutAudio();
    auto& engine = studio.getEngine();

    const auto drums = studio.addTrack (TrackType::drums);
    REQUIRE (studio.addPart (drums, "beat", 0).wasOk());

    studio.startGroovePreview (drums, "fill");
    CHECK (engine.isPreviewingGroove());
    studio.stopGroovePreview();
    CHECK (! engine.isPreviewingGroove());

    // A preview only plays through a drum track.
    studio.startGroovePreview (engine.getTrackOrder()[0], "fill");
    CHECK (! engine.isPreviewingGroove());

    // With no device in a test, the engine is prepared by hand so it can play.
    engine.prepare (48000.0, 512);
    studio.play();
    REQUIRE (engine.getState() != TransportState::stopped);
    CHECK (studio.addPart (drums, "fill", 96000).failed());
    studio.deleteClip (drums, 0);
    studio.commitDrag (drums, 0, DragZone::body, 96000, false);
    studio.stop();

    REQUIRE (engine.getDrumParts (drums).size() == 1);
    CHECK (engine.getDrumParts (drums)[0].startBar == 0);
}

//==============================================================================
TEST_CASE ("The app keeps its things where the JUCE RoughTrack does")
{
    const auto paths = StudioPaths::forApp();
    CHECK (paths.sessionsFolder.getFileName() == "RoughTrack");
    CHECK (paths.settingsFile.getFileName() == "RoughTrack.settings");
    CHECK (paths.pluginListFile.getFileName() == "RoughTrack.plugins.xml");
}

TEST_CASE ("The tuner listens to the armed audio track's input, or the first audio track's")
{
    const juce::ScopedJuceInitialiser_GUI juce;
    test::TempDirectory temp;

    Studio studio (pathsIn (temp.directory));
    studio.startWithoutAudio();
    auto& engine = studio.getEngine();

    const auto first = engine.getTrackOrder()[0];
    const auto second = studio.addTrack (TrackType::audio);
    studio.setTrackInput (second, 1, 1);

    studio.startTuner();
    CHECK (studio.isTunerRunning());
    CHECK (studio.getTunerDisplay().source == "Audio 1, Input 1");
    CHECK (! studio.getTunerDisplay().hasNote);

    studio.setTrackArmed (second, true);
    studio.tick();
    CHECK (studio.getTunerDisplay().source == engine.getTrackName (second) + ", Input 2");

    studio.stopTuner();
    CHECK (! studio.isTunerRunning());
    juce::ignoreUnused (first);
}

TEST_CASE ("Calibration waits for the transport to stop, and nothing is calibrated at first")
{
    const juce::ScopedJuceInitialiser_GUI juce;
    test::TempDirectory temp;

    Studio studio (pathsIn (temp.directory));
    studio.startWithoutAudio();
    CHECK (studio.getCalibratedLatency() == -1);

    studio.getEngine().prepare (48000.0, 512);
    studio.play();
    CHECK (studio.startCalibration().failed());
    CHECK (! studio.isCalibrating());
}

namespace
{

/** Runs the studio's timer until a mixdown finishes, as the app's would. */
std::optional<Studio::MixdownOutcome> waitForMixdown (Studio& studio)
{
    for (int i = 0; i < 2000 && studio.isMixingDown(); ++i)
    {
        juce::Thread::sleep (5);
        studio.tick();
    }

    return studio.takeMixdownOutcome();
}

} // namespace

TEST_CASE ("A mixdown and stems are written in the background, and refused while playing")
{
    const juce::ScopedJuceInitialiser_GUI juce;
    test::TempDirectory temp;

    Studio studio (pathsIn (temp.directory));
    studio.startWithoutAudio();
    auto& engine = studio.getEngine();
    engine.prepare (48000.0, 512);

    const auto track = engine.getTrackOrder()[0];
    CHECK (studio.startMixdown (studio.getMixdownFolder().getChildFile ("empty.wav"), false).failed());

    REQUIRE (engine.loadTake (track, writeTake (studio.getCurrentSession(), 48000), 0));

    const auto file = studio.getMixdownFolder().getChildFile ("Mix.wav");
    REQUIRE (studio.startMixdown (file, false).wasOk());
    CHECK (studio.isMixingDown());
    CHECK (studio.startMixdown (file, false).failed());

    const auto outcome = waitForMixdown (studio);
    REQUIRE (outcome.has_value());
    CHECK (outcome->result.result.wasOk());
    CHECK (! outcome->stems);
    CHECK (outcome->seconds >= 1.0);
    CHECK (outcome->result.peak > 0.1f);
    CHECK (file.existsAsFile());
    CHECK (! studio.takeMixdownOutcome().has_value());

    const auto folder = studio.getNextStemsFolder();
    CHECK (folder.getFileName() == "Session stems");
    REQUIRE (studio.startMixdown (folder, true).wasOk());
    const auto stems = waitForMixdown (studio);
    REQUIRE (stems.has_value());
    CHECK (stems->stems);
    CHECK (stems->numStems >= 1);
    CHECK (studio.getNextStemsFolder().getFileName() != "Session stems");

    // Cancelling as it starts leaves nothing behind.
    const auto cancelled = studio.getMixdownFolder().getChildFile ("Cancelled.wav");
    REQUIRE (studio.startMixdown (cancelled, false).wasOk());
    studio.cancelMixdown();
    const auto stopped = waitForMixdown (studio);
    REQUIRE (stopped.has_value());
    CHECK (stopped->result.result.failed());
    CHECK (! cancelled.existsAsFile());

    studio.play();
    REQUIRE (engine.getState() != TransportState::stopped);
    CHECK (studio.startMixdown (file, false).failed());
}

TEST_CASE ("A keyboard's buttons drive the transport and the tracks in its bank")
{
    const juce::ScopedJuceInitialiser_GUI juce;
    test::TempDirectory temp;

    Studio studio (pathsIn (temp.directory));
    studio.startWithoutAudio();
    auto& engine = studio.getEngine();
    engine.prepare (48000.0, 512);

    const auto first = engine.getTrackOrder()[0];
    const auto second = studio.addTrack (TrackType::audio);

    // The fader buttons: arm, solo and mute the bank's strips.
    studio.runControlCommand ({ ControlCommand::armStrip, 1 });
    CHECK (engine.isTrackArmed (second));
    studio.runControlCommand ({ ControlCommand::muteStrip, 0 });
    CHECK (engine.getTrackSettings (first).muted);
    studio.runControlCommand ({ ControlCommand::soloStrip, 5 });

    // Moving the arm up a track, and select arming just one.
    studio.runControlCommand ({ ControlCommand::previousTrack });
    CHECK (engine.isTrackArmed (first));
    CHECK (! engine.isTrackArmed (second));
    studio.runControlCommand ({ ControlCommand::selectStrip, 1 });
    CHECK (engine.isTrackArmed (second));
    CHECK (! engine.isTrackArmed (first));

    // Fast forward and rewind go bar by bar, while stopped.
    studio.runControlCommand ({ ControlCommand::fastForward });
    CHECK (engine.getPosition() == 96000);
    studio.runControlCommand ({ ControlCommand::rewind });
    CHECK (engine.getPosition() == 0);

    studio.runControlCommand ({ ControlCommand::toggleCycle });
    CHECK (engine.isCycleEnabled());

    // An MMC Play from any port reaches the transport through the timer.
    const juce::uint8 play[] = { 0x7f, 0x7f, 0x06, 0x02 };
    studio.getControllerInput().route ("keys", nullptr, juce::MidiMessage::createSysExMessage (play, (int) sizeof (play)));
    CHECK (engine.getState() == TransportState::stopped);
    studio.tick();
    CHECK (engine.getState() == TransportState::playing);

    // Stop, then stop again to go back to the start.
    studio.runControlCommand ({ ControlCommand::stop });
    CHECK (engine.getState() == TransportState::stopped);
    studio.seek (5000);
    studio.runControlCommand ({ ControlCommand::stop });
    CHECK (engine.getPosition() == 0);
}

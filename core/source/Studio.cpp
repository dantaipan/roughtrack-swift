#include "roughtrack/Studio.h"

#include "roughtrack/AudioDevices.h"
#include "roughtrack/ControlSurface.h"
#include "roughtrack/MicrophoneAccess.h"
#include "roughtrack/Midi.h"
#include "roughtrack/Session.h"

namespace roughtrack
{

namespace
{

constexpr double preferredSampleRate = 48000.0;
constexpr int preferredBufferSize = 64;
constexpr int timerHz = 30;
constexpr int autosaveTicks = 2 * timerHz;
constexpr auto defaultSessionName = "Session";
constexpr auto sessionFileName = "session.xml";
constexpr auto appName = "RoughTrack";

// Ships with macOS, so a MIDI track can make a sound with nothing else installed.
constexpr auto defaultInstrumentName = "DLSMusicDevice";

std::unique_ptr<juce::PropertiesFile> openSettings (const juce::File& file)
{
    juce::PropertiesFile::Options options;
    options.applicationName = appName;
    options.filenameSuffix = ".settings";
    return std::make_unique<juce::PropertiesFile> (file, options);
}

} // namespace

StudioPaths StudioPaths::forApp()
{
    const auto support = juce::File::getSpecialLocation (juce::File::userApplicationDataDirectory)
                             .getChildFile ("Application Support");
    const auto app = juce::File::getSpecialLocation (juce::File::currentApplicationFile);

    StudioPaths paths;
    paths.sessionsFolder = juce::File::getSpecialLocation (juce::File::userMusicDirectory).getChildFile (appName);
    paths.drumsFolder = app.getChildFile ("Contents/Resources/drums");
    paths.settingsFile = support.getChildFile (juce::String (appName) + ".settings");
    paths.pluginListFile = support.getChildFile (juce::String (appName) + ".plugins.xml");
    paths.scanExecutable = juce::File::getSpecialLocation (juce::File::currentExecutableFile);
    paths.useTone3000 = true;
    return paths;
}

Studio::Studio (StudioPaths pathsToUse)
    : paths (std::move (pathsToUse)),
      settings (openSettings (paths.settingsFile)),
      pluginLibrary (std::make_unique<PluginLibrary> (paths.pluginListFile))
{
    currentSession = paths.sessionsFolder.getChildFile (settings->getValue ("lastSession", defaultSessionName));
    engine.setSessionDirectory (currentSession);
    engine.setDrumFolder (paths.drumsFolder);

    if (paths.useTone3000)
    {
        Tone3000Hooks hooks;
        hooks.changed = [this] { changed(); };
        hooks.message = [this] (const juce::String& text, bool isWarning) { postMessage (text, isWarning); };
        hooks.tracks = [this] { return engine.getTrackOrder(); };
        hooks.fileOf = [this] (int track, Tone3000Target target)
        {
            const auto& channel = engine.getChannel (track);
            return target == Tone3000Target::amp ? channel.getAmpFile() : channel.getCabinetFile();
        };
        hooks.sourceOf = [this] (int track, Tone3000Target target)
        {
            const auto& channel = engine.getChannel (track);
            return target == Tone3000Target::amp ? channel.getAmpSource() : channel.getCabinetSource();
        };
        hooks.setSource = [this] (int track, Tone3000Target target, const FileSource& source)
        {
            auto& channel = engine.getChannel (track);
            target == Tone3000Target::amp ? channel.setAmpSource (source) : channel.setCabinetSource (source);
        };
        hooks.load = [this] (int track, Tone3000Target target, const juce::File& file, const FileSource& source)
        {
            return target == Tone3000Target::amp ? loadAmp (track, file, source) : loadCabinet (track, file, source);
        };
        tone3000 = std::make_unique<Tone3000> (std::move (hooks));
    }
}

Studio::~Studio()
{
    mixdownCancelled = true;

    if (mixdownThread.joinable())
        mixdownThread.join();

    if (updateThread.joinable())
        updateThread.join();

    closeEditors (-1);
    stopTimer();
    stopTuner();
    engine.stop();
    saveSession();
    saveInserts();
    midiDevices = {};

    if (audioStarted)
    {
        deviceManager.removeMidiInputDeviceCallback ({}, &controllerInput);
        deviceManager.removeChangeListener (this);
        deviceManager.removeAudioCallback (&engine);
        deviceManager.closeAudioDevice();
    }
}

void Studio::start()
{
    requestMicrophoneAccess ([weakThis = juce::WeakReference<Studio> (this)] (bool granted)
                             {
                                 juce::MessageManager::callAsync ([weakThis, granted]
                                                                  {
                                                                      if (weakThis == nullptr)
                                                                          return;

                                                                      if (granted)
                                                                          weakThis->startAudio();
                                                                      else
                                                                          weakThis->postMessage ("Microphone access was denied. Allow RoughTrack in "
                                                                                                 "System Settings > Privacy & Security > Microphone.",
                                                                                                 true);
                                                                  });
                             });
}

void Studio::startWithoutAudio()
{
    loadCurrentSession();
}

//==============================================================================
void Studio::startAudio()
{
    const auto savedState = settings->getXmlValue ("audioDevice");
    const auto error = deviceManager.initialise (256, 2, savedState.get(), true);

    if (error.isNotEmpty())
        postMessage (error, true);

    if (savedState == nullptr)
    {
        auto setup = deviceManager.getAudioDeviceSetup();
        setup.sampleRate = preferredSampleRate;
        setup.bufferSize = preferredBufferSize;
        deviceManager.setAudioDeviceSetup (setup, true);
    }

    useInterfaceInputs();

    deviceManager.addAudioCallback (&engine);
    deviceManager.addChangeListener (this);
    audioStarted = true;

    // Every keyboard plays the armed MIDI track, including ones plugged in later.
    enableMidiInputs();
    deviceManager.addMidiInputDeviceCallback ({}, &controllerInput);
    midiDevices = juce::MidiDeviceListConnection::make ([this] { enableMidiInputs(); });

    deviceChanged();
    startTimerHz (timerHz);
    loadCurrentSession();

    if (! pluginLibrary->hasBeenScanned())
        startPluginScan();
}

void Studio::enableMidiInputs()
{
    juce::StringArray identifiers, added;

    // A port chosen in Settings is kept by name, which survives replugging. With none
    // chosen, the port a keyboard sends its DAW controls on is picked by its name.
    const auto hasChoice = settings->containsKey ("controllerPort");
    const auto chosen = settings->getValue ("controllerPort");
    juce::MidiDeviceInfo controller;

    for (const auto& device : juce::MidiInput::getAvailableDevices())
    {
        deviceManager.setMidiInputDeviceEnabled (device.identifier, true);
        identifiers.add (device.identifier);

        if (audioStarted && ! midiInputs.contains (device.identifier))
            added.add (device.name);

        if (controller.identifier.isEmpty() && (hasChoice ? device.name == chosen : looksLikeControlPort (device.name)))
            controller = device;
    }

    midiInputs = identifiers;

    if (! added.isEmpty())
        postMessage ("MIDI input connected: " + added.joinIntoString (", "));

    if (controller.identifier == controllerInput.getControllerPort() && (controller.identifier.isEmpty() || controllerOutput != nullptr))
        return;

    controllerInput.setControllerPort (controller.identifier);
    controllerName = controller.name;
    controllerOutput.reset();
    litNotes.reset();

    // The buttons' lights are set through the output port of the same name, if there is one.
    if (controller.identifier.isNotEmpty())
        for (const auto& output : juce::MidiOutput::getAvailableDevices())
            if (output.name == controller.name)
                controllerOutput = juce::MidiOutput::openDevice (output.identifier);

    changed();
}

bool Studio::isControllerAutomatic() const
{
    return ! settings->containsKey ("controllerPort");
}

void Studio::chooseController (const juce::String& portName)
{
    settings->setValue ("controllerPort", portName);
    enableMidiInputs();
    changed();
}

void Studio::chooseControllerAutomatically()
{
    settings->removeValue ("controllerPort");
    enableMidiInputs();
    changed();
}

juce::StringArray Studio::getMidiInputNames() const
{
    juce::StringArray names;

    for (const auto& device : juce::MidiInput::getAvailableDevices())
        names.addIfNotAlreadyThere (device.name);

    return names;
}

void Studio::handleControlEvents()
{
    std::vector<ControlEvent> events;

    {
        const juce::SpinLock::ScopedLockType scope (controlLock);
        events.swap (pendingControls);
    }

    for (const auto& event : events)
        runControlCommand (event);
}

void Studio::runControlCommand (ControlEvent event)
{
    if (isMixingDown() || calibrating)
        return;

    const auto isStopped = engine.getState() == TransportState::stopped;

    switch (event.command)
    {
        case ControlCommand::play:
            if (isStopped)
                play();
            break;

        case ControlCommand::stop:
            // Stopping again goes back to the start, as in most DAWs.
            if (isStopped)
                returnToStart();
            else
                stop();
            break;

        case ControlCommand::record:
            if (engine.getState() == TransportState::recording)
                stop();
            else if (const auto result = record(); result.failed())
                postMessage (result.getErrorMessage(), true);
            break;

        case ControlCommand::rewind:
            if (isStopped)
                seek (previousBar (engine.getPosition(), getSamplesPerBar()));
            break;

        case ControlCommand::fastForward:
            if (isStopped)
                seek (nextBar (engine.getPosition(), getSamplesPerBar()));
            break;

        case ControlCommand::toggleCycle:
            setCycleEnabled (! engine.isCycleEnabled());
            break;

        case ControlCommand::previousTrack: moveArm (-1); break;
        case ControlCommand::nextTrack:     moveArm (1); break;

        case ControlCommand::armStrip:
        case ControlCommand::soloStrip:
        case ControlCommand::muteStrip:
        case ControlCommand::selectStrip:
            stripCommand (event);
            break;
    }

    changed();
}

std::vector<bool> Studio::armedByLane() const
{
    std::vector<bool> armed;

    for (const auto track : engine.getTrackOrder())
        armed.push_back (engine.isTrackArmed (track));

    return armed;
}

void Studio::stripCommand (ControlEvent event)
{
    const auto& order = engine.getTrackOrder();
    const auto lane = controllerBank + event.strip;

    if (! juce::isPositiveAndBelow (lane, (int) order.size()))
        return;

    const auto track = order[(size_t) lane];
    const auto trackSettings = engine.getTrackSettings (track);
    const auto isRecording = engine.getState() == TransportState::recording;

    if (event.command == ControlCommand::soloStrip)
        setTrackSoloed (track, ! trackSettings.soloed);
    else if (event.command == ControlCommand::muteStrip)
        setTrackMuted (track, ! trackSettings.muted);
    else if (event.command == ControlCommand::armStrip && ! isRecording)
        setTrackArmed (track, ! engine.isTrackArmed (track));
    else if (event.command == ControlCommand::selectStrip && ! isRecording)
        for (const auto other : order)
            if (engine.isTrackArmed (other) != (other == track))
                setTrackArmed (other, other == track);
}

void Studio::moveArm (int direction)
{
    if (engine.getState() == TransportState::recording)
        return;

    const auto& order = engine.getTrackOrder();
    const auto armed = armedByLane();
    const auto lane = nextArmedLane (armed, direction);

    if (lane < 0)
        return;

    for (size_t i = 0; i < order.size(); ++i)
        if (armed[i] != ((int) i == lane))
            setTrackArmed (order[i], (int) i == lane);
}

void Studio::showControllerLights()
{
    // The fader buttons follow the armed track's bank, and stay put when nothing is armed.
    const auto armed = armedByLane();

    if (std::find (armed.begin(), armed.end(), true) != armed.end())
        controllerBank = bankStart (armed);

    controllerBank = juce::jlimit (0, juce::jmax (0, (int) armed.size() - 1) / stripsPerBank * stripsPerBank, controllerBank);

    if (controllerOutput == nullptr)
        return;

    const auto state = engine.getState();
    std::array<bool, 128> lit {};

    lit[(size_t) mackie::play] = state != TransportState::stopped;
    lit[(size_t) mackie::stop] = state == TransportState::stopped;
    lit[(size_t) mackie::record] = state == TransportState::recording;
    lit[(size_t) mackie::cycle] = engine.isCycleEnabled();

    const auto& order = engine.getTrackOrder();

    for (int strip = 0; strip < stripsPerBank; ++strip)
    {
        const auto lane = controllerBank + strip;

        if (lane >= (int) order.size())
            break;

        const auto track = order[(size_t) lane];
        const auto trackSettings = engine.getTrackSettings (track);

        lit[(size_t) (mackie::firstRecord + strip)] = engine.isTrackArmed (track);
        lit[(size_t) (mackie::firstSelect + strip)] = engine.isTrackArmed (track);
        lit[(size_t) (mackie::firstSolo + strip)] = trackSettings.soloed;
        lit[(size_t) (mackie::firstMute + strip)] = trackSettings.muted;
    }

    // Only changes are sent, and every light once when the controller arrives.
    const auto send = [&] (int note)
    {
        if (! litNotes.has_value() || (*litNotes)[(size_t) note] != lit[(size_t) note])
            controllerOutput->sendMessageNow (mackieLight (note, lit[(size_t) note]));
    };

    for (int note = 0; note < mackie::firstSelect + stripsPerBank; ++note)
        send (note);

    for (const auto note : { mackie::play, mackie::stop, mackie::record, mackie::cycle })
        send (note);

    litNotes = lit;
}

//==============================================================================
void Studio::startTuner()
{
    const auto rate = engine.getSampleRate() > 0.0 ? engine.getSampleRate() : preferredSampleRate;
    tunerDetector = std::make_unique<PitchDetector> (rate);
    tunerHistory.assign ((size_t) tunerDetector->getWindowSize(), 0.0f);
    tunerArriving.resize (tunerHistory.size());
    tunerSamplesSinceAnalysis = 0;
    tunerRecentCents.clear();
    tunerNote = -1;
    tunerCents = 0.0;
    updateTuner (0.0);

    // What was copied before is old news.
    while (engine.readTuner (tunerArriving.data(), (int) tunerArriving.size()) > 0) {}
}

void Studio::stopTuner()
{
    engine.setTunerInput (-1);
    tunerDetector.reset();
    tunerNote = -1;
}

Studio::TunerDisplay Studio::getTunerDisplay() const
{
    TunerDisplay display;
    display.hasNote = tunerNote >= 0;
    display.note = tunerNote >= 0 ? getTunerNoteName (tunerNote) : juce::String();
    display.cents = tunerCents;
    display.source = tunerSource;
    return display;
}

void Studio::updateTuner (double secondsSinceLast)
{
    constexpr int samplesBetweenAnalyses = 2048;
    constexpr size_t readingsSmoothed = 5;
    constexpr double secondsNoteStays = 1.5;

    if (tunerDetector == nullptr)
        return;

    // The armed audio track's input, or the first audio track's.
    auto track = -1;

    for (const auto candidate : engine.getTrackOrder())
    {
        if (engine.getTrackType (candidate) != TrackType::audio)
            continue;

        if (track < 0 || engine.isTrackArmed (candidate))
            track = candidate;

        if (engine.isTrackArmed (candidate))
            break;
    }

    const auto input = track >= 0 ? engine.getTrackSettings (track).firstInput : 0;
    engine.setTunerInput (input);
    tunerSource = (track >= 0 ? engine.getTrackName (track) + ", " : juce::String()) + "Input " + juce::String (input + 1);

    tunerSecondsSinceNote += secondsSinceLast;

    for (;;)
    {
        const auto numRead = engine.readTuner (tunerArriving.data(), (int) tunerArriving.size());

        if (numRead == 0)
            break;

        std::move (tunerHistory.begin() + numRead, tunerHistory.end(), tunerHistory.begin());
        std::copy_n (tunerArriving.begin(), numRead, tunerHistory.end() - numRead);
        tunerSamplesSinceAnalysis += numRead;

        if (tunerSamplesSinceAnalysis < samplesBetweenAnalyses)
            continue;

        tunerSamplesSinceAnalysis = 0;
        const auto reading = tunerDetector->analyse (tunerHistory.data());

        if (! reading.hasPitch)
            continue;

        // A plucked string starts sharp and wobbles, so a few readings are taken together.
        if (reading.note != tunerNote)
            tunerRecentCents.clear();

        tunerNote = reading.note;
        tunerSecondsSinceNote = 0.0;
        tunerRecentCents.push_back (reading.cents);

        if (tunerRecentCents.size() > readingsSmoothed)
            tunerRecentCents.erase (tunerRecentCents.begin());

        auto sorted = tunerRecentCents;
        std::sort (sorted.begin(), sorted.end());
        tunerCents = sorted[sorted.size() / 2];
    }

    if (tunerNote >= 0 && tunerSecondsSinceNote > secondsNoteStays)
    {
        tunerNote = -1;
        tunerRecentCents.clear();
    }
}

//==============================================================================
juce::Result Studio::startCalibration()
{
    if (calibrating)
        return juce::Result::fail ("Calibration is already running.");

    if (engine.getState() != TransportState::stopped)
        return juce::Result::fail ("Stop the transport to calibrate.");

    const auto result = engine.startCalibration (0);
    calibrating = result.wasOk();
    calibrationResult.reset();
    return result;
}

std::optional<LatencyCalibrator::Result> Studio::takeCalibrationResult()
{
    auto result = calibrationResult;
    calibrationResult.reset();
    return result;
}

int Studio::getCalibratedLatency() const
{
    return settings->containsKey (latencyKey()) ? settings->getIntValue (latencyKey()) : -1;
}

//==============================================================================
juce::File Studio::getMixdownFolder() const
{
    return currentSession.getChildFile ("Mixdowns");
}

juce::File Studio::getNextStemsFolder() const
{
    return getMixdownFolder().getNonexistentChildFile (currentSession.getFileName() + " stems", {}, true);
}

juce::Result Studio::startMixdown (const juce::File& destination, bool stems)
{
    if (isMixingDown())
        return juce::Result::fail ("A mixdown is already running.");

    if (engine.getState() != TransportState::stopped)
        return juce::Result::fail (stems ? "Stop the transport to export stems." : "Stop the transport to mix down.");

    const auto end = engine.getSessionLength();

    if (end <= 0)
        return juce::Result::fail ("There's nothing to mix down yet.");

    if (const auto folder = stems ? destination : destination.getParentDirectory(); ! folder.createDirectory())
        return juce::Result::fail ("Couldn't make the folder " + folder.getFullPathName() + ".");

    mixdownReturnPosition = engine.getPosition();
    mixdownWork = {};
    mixdownWork.file = destination;
    mixdownWork.stems = stems;
    mixdownProgress = 0.0;
    mixdownCancelled = false;
    mixdownRunning = true;

    mixdownThread = std::thread ([this, destination, stems, end]
    {
        const auto shouldContinue = [this] (double progress)
        {
            mixdownProgress = progress;
            return ! mixdownCancelled.load();
        };

        mixdownWork.result = stems ? engine.bounceStems (destination, 0, end, shouldContinue)
                                   : engine.bounce (destination, 0, end, shouldContinue);
        mixdownRunning = false;
    });

    changed();
    return juce::Result::ok();
}

void Studio::finishMixdown()
{
    if (! mixdownThread.joinable() || mixdownRunning.load())
        return;

    mixdownThread.join();

    auto outcome = mixdownWork;
    const auto rate = engine.getSampleRate() > 0.0 ? engine.getSampleRate() : getTimelineRate();
    outcome.seconds = (double) outcome.result.numSamples / rate;

    if (outcome.stems)
        outcome.numStems = outcome.file.getNumberOfChildFiles (juce::File::findFiles, "*.wav");

    mixdownOutcome = outcome;
    changed();
}

std::optional<Studio::MixdownOutcome> Studio::takeMixdownOutcome()
{
    auto outcome = mixdownOutcome;
    mixdownOutcome.reset();
    return outcome;
}

//==============================================================================
void Studio::checkForUpdates (bool isManual)
{
    if (updateThread.joinable())
        return;

    if (! updates::isUpdateCheckingAvailable())
    {
        if (isManual)
            updateOutcome = UpdateOutcome { std::nullopt, "Checking for updates isn't set up yet.", true };

        return;
    }

    updateWork = {};
    updateWork.isManual = isManual;
    updateRunning = true;

    updateThread = std::thread ([this]
    {
        updateWork.release = updates::fetchLatestRelease (ROUGHTRACK_VERSION, updateWork.error);
        updateRunning = false;
    });
}

std::optional<Studio::UpdateOutcome> Studio::takeUpdateOutcome()
{
    auto outcome = updateOutcome;
    updateOutcome.reset();
    return outcome;
}

void Studio::skipUpdate (const juce::String& version)
{
    settings->setValue ("skippedVersion", version);
}

bool Studio::checksForUpdatesAutomatically() const
{
    return settings->getBoolValue ("checkForUpdates", true);
}

void Studio::setChecksForUpdatesAutomatically (bool shouldCheck)
{
    settings->setValue ("checkForUpdates", shouldCheck);
}

void Studio::useInterfaceInputs()
{
    auto* type = deviceManager.getCurrentDeviceTypeObject();

    if (type == nullptr)
        return;

    std::vector<std::string> inputs;

    for (const auto& name : type->getDeviceNames (true))
        inputs.push_back (name.toStdString());

    auto setup = deviceManager.getAudioDeviceSetup();

    const juce::String preferred (preferredInputDevice (setup.outputDeviceName.toStdString(),
                                                        setup.inputDeviceName.toStdString(),
                                                        inputs));

    if (preferred == setup.inputDeviceName)
        return;

    setup.inputDeviceName = preferred;
    setup.useDefaultInputChannels = true;

    if (const auto error = deviceManager.setAudioDeviceSetup (setup, true); error.isNotEmpty())
        postMessage (error, true);
}

juce::String Studio::deviceDescription() const
{
    const auto setup = deviceManager.getAudioDeviceSetup();

    if (setup.inputDeviceName == setup.outputDeviceName)
        return setup.outputDeviceName;

    return "Out: " + setup.outputDeviceName + ", In: "
           + (setup.inputDeviceName.isNotEmpty() ? setup.inputDeviceName : juce::String ("none"));
}

juce::String Studio::chooseAudioDevice (const juce::String& outputName, double sampleRate, int bufferSize)
{
    auto setup = deviceManager.getAudioDeviceSetup();
    setup.outputDeviceName = outputName;
    setup.inputDeviceName = outputName;
    setup.sampleRate = sampleRate;
    setup.bufferSize = bufferSize;
    setup.useDefaultInputChannels = true;
    setup.useDefaultOutputChannels = true;

    auto error = deviceManager.setAudioDeviceSetup (setup, true);

    // An output-only device records from the built-in or another input.
    useInterfaceInputs();

    if (error.isEmpty())
        if (const auto state = deviceManager.createStateXml())
            settings->setValue ("audioDevice", state.get());

    lastAudioRestoreFrom = {};
    deviceChanged();
    return error;
}

void Studio::changeListenerCallback (juce::ChangeBroadcaster*)
{
    deviceChanged();
}

void Studio::deviceChanged()
{
    // Only the first device is remembered for now. Choosing one in Settings comes later,
    // and a fallback while the interface is unplugged mustn't replace it.
    if (! settings->containsKey ("audioDevice"))
        if (const auto state = deviceManager.createStateXml())
            settings->setValue ("audioDevice", state.get());

    if (settings->containsKey (latencyKey()))
        engine.setRecordingLatency (settings->getIntValue (latencyKey()));

    // A capture that couldn't load at the old rate may load at this one.
    if (const auto loaded = engine.retryAmps(); loaded > 0)
        postMessage (loaded == 1 ? juce::String ("A capture that was waiting for its sample rate is loaded.")
                                 : juce::String (loaded) + " captures that were waiting for their sample rate are loaded.");

    changed();
}

// Latency differs between interfaces and with every rate and buffer size, so
// each combination is calibrated once and remembered.
juce::String Studio::latencyKey() const
{
    if (auto* device = deviceManager.getCurrentAudioDevice())
        return "latency " + deviceDescription() + " " + juce::String (device->getCurrentSampleRate()) + " "
               + juce::String (device->getCurrentBufferSizeSamples());

    return "latency none";
}

void Studio::restoreChosenAudioDevice()
{
    auto* device = deviceManager.getCurrentAudioDevice();
    auto* type = deviceManager.getCurrentDeviceTypeObject();
    const auto chosenXml = settings->getXmlValue ("audioDevice");

    if (type == nullptr || engine.getState() != TransportState::stopped)
        return;

    const auto setup = deviceManager.getAudioDeviceSetup();
    const AudioDeviceChoice current { setup.outputDeviceName.toStdString(),
                                      device != nullptr ? device->getCurrentSampleRate() : 0.0,
                                      device != nullptr ? device->getCurrentBufferSizeSamples() : 0 };

    const auto picked = chosenXml != nullptr ? AudioDeviceChoice { chosenXml->getStringAttribute ("audioOutputDeviceName").toStdString(),
                                                                   chosenXml->getDoubleAttribute ("audioDeviceRate"),
                                                                   chosenXml->getIntAttribute ("audioDeviceBufferSize") }
                                             : AudioDeviceChoice {};

    std::vector<std::string> outputs;

    for (const auto& name : type->getDeviceNames (false))
        outputs.push_back (name.toStdString());

    const auto chosen = wantedAudioDevice (picked, current, engine.getSessionSampleRate(), outputs);
    const auto usesPicked = ! picked.outputDevice.empty() && chosen.outputDevice == picked.outputDevice;

    if (! shouldRestoreAudioDevice (chosen, current, outputs))
    {
        lastAudioRestoreFrom = {};
        return;
    }

    // One try from each state, so a device that refuses the choice isn't restarted forever.
    const auto from = juce::String (current.outputDevice) + " " + juce::String (current.sampleRate) + " " + juce::String (current.bufferSize);

    if (from == lastAudioRestoreFrom)
        return;

    lastAudioRestoreFrom = from;

    auto restored = setup;

    if (usesPicked)
    {
        restored.outputDeviceName = chosenXml->getStringAttribute ("audioOutputDeviceName");
        restored.inputDeviceName = chosenXml->getStringAttribute ("audioInputDeviceName");
    }

    restored.sampleRate = chosen.sampleRate;
    restored.bufferSize = chosen.bufferSize;
    restored.useDefaultInputChannels = true;
    restored.useDefaultOutputChannels = true;

    const auto onlyTheRate = restored.outputDeviceName.toStdString() == current.outputDevice && chosen.bufferSize == current.bufferSize;

    if (const auto error = deviceManager.setAudioDeviceSetup (restored, false); error.isNotEmpty())
        postMessage ("Couldn't return to " + restored.outputDeviceName + ": " + error, true);
    else if (onlyTheRate)
        postMessage ("Set " + restored.outputDeviceName + " to " + juce::String (describeSampleRate (chosen.sampleRate)) + " to match this session.");
    else
        postMessage ("Back on " + restored.outputDeviceName + " at " + juce::String (chosen.bufferSize) + " samples.");
}

//==============================================================================
juce::Array<juce::File> Studio::listSessions() const
{
    auto folders = paths.sessionsFolder.findChildFiles (juce::File::findDirectories, false);
    folders.sort();
    return folders;
}

juce::Result Studio::newSession (const juce::String& name)
{
    const auto legalName = juce::File::createLegalFileName (name.trim());

    if (legalName.isEmpty())
        return juce::Result::fail ("A session needs a name.");

    const auto folder = paths.sessionsFolder.getChildFile (legalName);

    if (folder.exists())
        return juce::Result::fail ("There's already a session called " + legalName + ".");

    openSession (folder);
    return juce::Result::ok();
}

void Studio::loadCurrentSession()
{
    const auto sessionFile = currentSession.getChildFile (sessionFileName);
    const auto xml = juce::parseXML (sessionFile);

    // Autosave would replace a damaged file, so it's kept for recovery.
    if (sessionFile.existsAsFile() && xml == nullptr)
    {
        sessionFile.copyFileTo (sessionFile.withFileExtension ("damaged.xml"));
        postMessage ("The session file couldn't be read. A copy was kept beside it.", true);
    }

    sessionLoaded = true;

    if (xml != nullptr)
        if (const auto result = applySessionXml (engine, *xml, currentSession); result.failed())
            postMessage (result.getErrorMessage(), true);

    // The grid is a choice about this song, so it's kept with it. Older sessions get bars.
    snap = snapFromId (xml != nullptr ? xml->getStringAttribute ("snap") : juce::String());

    if (engine.getTrackOrder().empty())
        engine.addTrack ("Audio 1");

    restoreInserts();
    changed();

    // Captures and IRs from TONE3000 that have gone are downloaded again.
    if (tone3000 != nullptr)
        tone3000->checkTracks();

    // A new session may want another rate, so it gets its own try at switching.
    lastAudioRestoreFrom = {};

    if (audioStarted)
        restoreChosenAudioDevice();
}

// Nothing is saved until a session has loaded, or quitting early, such as with
// microphone access denied, would write an empty session over the real one.
void Studio::saveSession()
{
    if (! sessionLoaded || engine.getState() != TransportState::stopped)
        return;

    auto xml = createSessionXml (engine, currentSession);
    xml->setAttribute ("snap", getSnapId (snap));
    const auto text = xml->toString();

    if (text == lastSavedSession)
        return;

    currentSession.createDirectory();

    if (currentSession.getChildFile (sessionFileName).replaceWithText (text))
        lastSavedSession = text;
    else
        postMessage ("Couldn't save the session to " + currentSession.getFullPathName(), true);
}

void Studio::openSession (const juce::File& directory)
{
    if (numInsertsRestoring > 0)
    {
        postMessage ("Plugins are still loading. Try again in a moment.");
        return;
    }

    engine.stop();
    engine.stopGroovePreview();
    saveSession();
    saveInserts();
    closeEditors (-1);

    engine.removeAllTracks();
    engine.resetChannels();

    // Tempo, click, master level and loop belong to their song. A new session has no
    // file to load them from, so without this it would keep the last session's.
    engine.resetSessionSettings();

    undoManager.clearUndoHistory();
    insertsNeedKeeping = false;
    sessionLoaded = false;
    lastSavedSession.clear();

    currentSession = directory;
    currentSession.createDirectory();
    engine.setSessionDirectory (currentSession);
    engine.setPosition (0);
    settings->setValue ("lastSession", currentSession.getFileName());

    loadCurrentSession();
    postMessage ("Opened " + currentSession.getFileName() + ".");
}

//==============================================================================
void Studio::play()
{
    if (isMixingDown() || calibrating)
        return;

    engine.play();
}

void Studio::stop()
{
    engine.stop();
}

juce::Result Studio::record()
{
    if (engine.getState() == TransportState::recording)
        return juce::Result::ok();

    if (isMixingDown() || calibrating)
        return juce::Result::fail ("Wait for the mixdown or calibration to finish.");

    for (int track = 0; track < maxTracks; ++track)
        clipsBeforeRecording[(size_t) track] = engine.getClips (track);

    const auto result = engine.record();
    recordingInProgress = result.wasOk();
    return result;
}

void Studio::returnToStart()
{
    engine.stop();
    engine.setPosition (0);
}

void Studio::seek (juce::int64 position)
{
    if (engine.getState() == TransportState::stopped)
        engine.setPosition (juce::jmax ((juce::int64) 0, position));
    else
        postMessage ("Stop the transport to move the playhead.");
}

void Studio::recordingFinished()
{
    recordingInProgress = false;
    undoManager.beginNewTransaction ("Record");

    for (int track = 0; track < maxTracks; ++track)
        if (engine.getClips (track) != clipsBeforeRecording[(size_t) track])
            undoManager.perform (new ClipEdit (engine, track, clipsBeforeRecording[(size_t) track], engine.getClips (track)));

    changed();
    saveSession();

    if (const auto health = engine.getLastTakeHealth(); ! health.isClean())
        postMessage ("The last take has audio gaps (" + juce::String (health.dropouts) + " dropouts, "
                         + juce::String (health.droppedSamples) + " samples lost). Record it again if it matters.",
                     true);
}

//==============================================================================
void Studio::setTrackMuted (int track, bool shouldBeMuted)
{
    engine.setTrackMuted (track, shouldBeMuted);
    changed();
}

void Studio::setTrackSoloed (int track, bool shouldBeSoloed)
{
    engine.setTrackSoloed (track, shouldBeSoloed);
    changed();
}

void Studio::setTrackArmed (int track, bool shouldBeArmed)
{
    engine.setTrackArmed (track, shouldBeArmed);
    changed();
}

void Studio::setTrackMonitoring (int track, bool shouldMonitor)
{
    engine.setTrackMonitoring (track, shouldMonitor);
    changed();
}

void Studio::renameTrack (int track, const juce::String& name)
{
    const auto trimmed = name.trim();

    if (trimmed.isEmpty() || ! engine.isTrackActive (track))
        return;

    engine.setTrackName (track, trimmed);
    changed();
    saveSession();
}

juce::String Studio::nextTrackName (const juce::String& baseName) const
{
    const auto isTaken = [this] (const juce::String& name)
    {
        for (const auto track : engine.getTrackOrder())
            if (engine.getTrackName (track) == name)
                return true;

        return false;
    };

    // Audio tracks are numbered from the start, because there are usually several.
    if (baseName != "Audio" && ! isTaken (baseName))
        return baseName;

    for (int number = baseName == "Audio" ? 1 : 2;; ++number)
        if (const auto name = baseName + " " + juce::String (number); ! isTaken (name))
            return name;
}

int Studio::addTrack (TrackType type)
{
    if (type == TrackType::drums)
    {
        if (const auto drums = engine.loadDrums(); drums.failed())
        {
            postMessage (drums.getErrorMessage(), true);
            return -1;
        }
    }

    const auto baseName = type == TrackType::drums ? "Drums" : (type == TrackType::midi ? "MIDI" : "Audio");
    const auto track = engine.addTrack (nextTrackName (baseName), type);

    if (track < 0)
    {
        postMessage (engine.getState() == TransportState::stopped ? "A session can have up to " + juce::String (maxTracks) + " tracks."
                                                                   : juce::String ("Stop the transport to add a track."));
        return -1;
    }

    changed();
    saveSession();

    if (type == TrackType::midi)
        loadDefaultInstrument (track);

    return track;
}

void Studio::loadDefaultInstrument (int track)
{
    for (const auto& instrument : pluginLibrary->getInstruments())
    {
        if (instrument.name == defaultInstrumentName)
        {
            SavedInsert insert;
            insert.track = track;
            insert.slot = instrumentSlot;
            insert.description = instrument;
            loadInsert (track, instrumentSlot, insert);
            return;
        }
    }
}

juce::Result Studio::deleteTrack (int track)
{
    if (engine.getTrackOrder().size() <= 1)
        return juce::Result::fail ("A session needs at least one track.");

    if (engine.getState() != TransportState::stopped)
        return juce::Result::fail ("Stop the transport to delete a track.");

    engine.stopGroovePreview();
    closeEditors (track);

    if (const auto result = engine.removeTrack (track); result.failed())
        return result;

    undoManager.clearUndoHistory();
    changed();
    saveSession();
    saveInserts();
    return juce::Result::ok();
}

void Studio::moveTrack (int track, int newPosition)
{
    engine.moveTrack (track, newPosition);
    changed();
    saveSession();
}

//==============================================================================
void Studio::setTrackGain (int track, float linearGain)
{
    engine.setTrackGain (track, juce::jlimit (0.0f, 4.0f, linearGain));
    changed();
}

void Studio::setTrackPan (int track, float pan)
{
    engine.setTrackPan (track, juce::jlimit (-1.0f, 1.0f, pan));
    changed();
}

void Studio::setTrackInverted (int track, bool shouldBeInverted)
{
    engine.setTrackInverted (track, shouldBeInverted);
    changed();
    saveSession();
}

void Studio::setTrackInput (int track, int firstInputChannel, int numChannels)
{
    engine.setTrackInput (track, juce::jmax (0, firstInputChannel), juce::jlimit (1, 2, numChannels));
    changed();
    saveSession();
}

void Studio::setMasterGain (float linearGain)
{
    engine.setMasterGain (juce::jlimit (0.0f, 4.0f, linearGain));
    changed();
}

void Studio::setTempo (double beatsPerMinute)
{
    engine.setTempo (juce::jlimit (20.0, 300.0, beatsPerMinute));
    changed();
    saveSession();
}

void Studio::setClickEnabled (bool shouldClick)
{
    engine.setClickEnabled (shouldClick);
    changed();
    saveSession();
}

void Studio::setChannelParameter (int track, ChannelParameter parameter, float value)
{
    engine.getChannel (track).setParameter (parameter, value);
    changed();
}

void Studio::setAuxParameter (AuxParameter parameter, float value)
{
    engine.getAux().setParameter (parameter, value);
    changed();
}

int Studio::getNumInputChannels() const
{
    if (auto* device = deviceManager.getCurrentAudioDevice())
        return device->getActiveInputChannels().countNumberOfSetBits();

    return 0;
}

juce::Result Studio::loadAmp (int track, const juce::File& capture, const FileSource& source)
{
    const auto result = engine.loadAmp (track, capture);

    if (result.wasOk())
    {
        engine.getChannel (track).setAmpSource (source);

        // Downloads have their own folder; the open panel keeps to the player's library.
        if (! source.isValid())
            settings->setValue ("ampFolder", capture.getParentDirectory().getFullPathName());

        changed();
        saveSession();
    }

    return result;
}

void Studio::removeAmp (int track)
{
    engine.removeAmp (track);
    changed();
    saveSession();
}

juce::Result Studio::loadCabinet (int track, const juce::File& impulse, const FileSource& source)
{
    const auto result = engine.getChannel (track).loadCabinet (impulse);

    if (result.wasOk())
    {
        engine.getChannel (track).setCabinetSource (source);

        if (! source.isValid())
            settings->setValue ("ampFolder", impulse.getParentDirectory().getFullPathName());

        changed();
        saveSession();
    }

    return result;
}

void Studio::clearCabinet (int track)
{
    engine.getChannel (track).clearCabinet();
    changed();
    saveSession();
}

juce::File Studio::getAmpFolder() const
{
    const auto saved = settings->getValue ("ampFolder");
    return saved.isNotEmpty() ? juce::File (saved) : juce::File::getSpecialLocation (juce::File::userDocumentsDirectory);
}

//==============================================================================
juce::Result Studio::loadPlugin (int track, int slot, int libraryIndex)
{
    if (engine.getState() != TransportState::stopped)
        return juce::Result::fail ("Stop the transport to change plugins.");

    const auto& list = slot == instrumentSlot ? pluginLibrary->getInstruments() : pluginLibrary->getPlugins();

    if (! juce::isPositiveAndBelow (libraryIndex, (int) list.size()) || ! juce::isPositiveAndBelow (slot, instrumentSlot + 1))
        return juce::Result::fail ("That plugin isn't in the list. Try Rescan Plugins.");

    SavedInsert insert;
    insert.track = track;
    insert.slot = slot;
    insert.description = list[(size_t) libraryIndex];
    loadInsert (track, slot, insert);
    return juce::Result::ok();
}

void Studio::removePlugin (int track, int slot)
{
    if (! canChangeInserts())
        return;

    closeEditors (track, slot);
    engine.removeInsert (track, slot);
    changed();
    saveInserts();
}

void Studio::setPluginBypassed (int track, int slot, bool shouldBypass)
{
    engine.setInsertBypassed (track, slot, shouldBypass);
    changed();
    saveInserts();
}

void Studio::setPluginBeforeAmp (int track, int slot, bool shouldBeBeforeAmp)
{
    if (! canChangeInserts())
        return;

    engine.setInsertBeforeAmp (track, slot, shouldBeBeforeAmp);
    changed();
    saveInserts();
}

void Studio::rescanPlugins()
{
    if (pluginLibrary->isScanning())
        return;

    postMessage ("Scanning plugins...");
    startPluginScan();
}

//==============================================================================
int Studio::openEditor (int track, int slot, void* parentView)
{
    auto* plugin = engine.getInsert (track, slot);

    if (plugin == nullptr || parentView == nullptr)
        return 0;

    const auto handle = nextEditorHandle++;
    editors[handle] = std::make_unique<HostedEditor> (*plugin, parentView, track, slot);
    return handle;
}

juce::Rectangle<int> Studio::getEditorSize (int handle) const
{
    if (const auto found = editors.find (handle); found != editors.end())
        return found->second->getSize();

    return {};
}

bool Studio::isEditorResizable (int handle) const
{
    const auto found = editors.find (handle);
    return found != editors.end() && found->second->isResizable();
}

void Studio::resizeEditor (int handle, int width, int height)
{
    if (const auto found = editors.find (handle); found != editors.end())
        found->second->setSize (width, height);
}

void Studio::closeEditor (int handle)
{
    if (editors.erase (handle) > 0)
        saveInserts();
}

void Studio::closeEditors (int track, int slot)
{
    for (auto it = editors.begin(); it != editors.end();)
    {
        const auto& editor = *it->second;

        if (track < 0 || (editor.track == track && (slot < 0 || editor.slot == slot)))
            it = editors.erase (it);
        else
            ++it;
    }
}

//==============================================================================
double Studio::getTimelineRate() const
{
    const auto rate = engine.getSampleRate();
    return rate > 0.0 ? rate : preferredSampleRate;
}

double Studio::getSamplesPerBeat() const
{
    return getTimelineRate() * 60.0 / engine.getTempo();
}

juce::int64 Studio::toClipUnits (int track, juce::int64 samples) const
{
    if (engine.getTrackType (track) != TrackType::midi)
        return samples;

    return (juce::int64) std::llround ((double) samples * ticksPerBeat / getSamplesPerBeat());
}

juce::int64 Studio::toSamples (int track, juce::int64 clipUnits) const
{
    if (engine.getTrackType (track) != TrackType::midi)
        return clipUnits;

    return (juce::int64) std::llround ((double) clipUnits * getSamplesPerBeat() / ticksPerBeat);
}

void Studio::setSnap (SnapGrid newSnap)
{
    snap = newSnap;
    changed();
    saveSession();
}

juce::int64 Studio::snapPosition (juce::int64 samples, bool placeFreely) const
{
    return juce::jmax ((juce::int64) 0, snapToGrid (samples, placeFreely ? SnapGrid::off : snap, getSamplesPerBeat()));
}

bool Studio::canEdit()
{
    if (engine.getState() == TransportState::stopped)
        return true;

    postMessage ("Stop the transport to edit.");
    return false;
}

//==============================================================================
ClipList Studio::previewDrag (int track, int clip, DragZone zone, juce::int64 distance, bool placeFreely) const
{
    const auto beat = engine.getTrackType (track) == TrackType::midi ? (double) ticksPerBeat : getSamplesPerBeat();

    return dragClip (engine.getClips (track),
                     clip,
                     zone,
                     toClipUnits (track, distance),
                     placeFreely ? SnapGrid::off : snap,
                     beat,
                     engine.getLoopEnd (track, clip));
}

void Studio::commitDrag (int track, int clip, DragZone zone, juce::int64 distance, bool placeFreely)
{
    if (! canEdit())
        return;

    if (isDrums (track))
    {
        if (const auto parts = previewPartDrag (track, clip, zone, distance); parts != engine.getDrumParts (track))
            applyDrumEdit (track, parts, partDragEditName (zone));

        return;
    }

    if (const auto clips = previewDrag (track, clip, zone, distance, placeFreely); clips != engine.getClips (track))
        applyClipEdit (track, clips, dragEditName (zone));
}

void Studio::splitClip (int track, int clip, juce::int64 position, bool placeFreely)
{
    if (isDrums (track))
    {
        if (! canEdit() || ! juce::isPositiveAndBelow (clip, (int) engine.getDrumParts (track).size()))
            return;

        const auto bar = juce::roundToInt ((double) position / getSamplesPerBar());

        if (const auto parts = splitPart (engine.getDrumParts (track), clip, bar); parts != engine.getDrumParts (track))
            applyDrumEdit (track, parts, "Split Part");

        return;
    }

    if (! canEdit() || ! juce::isPositiveAndBelow (clip, (int) engine.getClips (track).size()))
        return;

    const auto beat = engine.getTrackType (track) == TrackType::midi ? (double) ticksPerBeat : getSamplesPerBeat();
    const auto at = snapToGrid (toClipUnits (track, position), placeFreely ? SnapGrid::off : snap, beat);

    if (const auto clips = roughtrack::splitClip (engine.getClips (track), clip, at); clips != engine.getClips (track))
        applyClipEdit (track, clips, "Split Clip");
}

void Studio::deleteClip (int track, int clip)
{
    if (isDrums (track))
    {
        if (canEdit() && juce::isPositiveAndBelow (clip, (int) engine.getDrumParts (track).size()))
            applyDrumEdit (track, removePart (engine.getDrumParts (track), clip), "Delete Part");

        return;
    }

    if (canEdit() && juce::isPositiveAndBelow (clip, (int) engine.getClips (track).size()))
        applyClipEdit (track, removeClip (engine.getClips (track), clip), "Delete Clip");
}

void Studio::setClipLooping (int track, int clip, bool shouldLoop)
{
    if (isDrums (track))
    {
        if (! canEdit() || ! juce::isPositiveAndBelow (clip, (int) engine.getDrumParts (track).size()))
            return;

        auto parts = engine.getDrumParts (track);
        parts[(size_t) clip].loopsToNext = shouldLoop;
        applyDrumEdit (track, parts, shouldLoop ? "Loop Until Next Part" : "Stop Looping");
        return;
    }

    if (! canEdit() || ! juce::isPositiveAndBelow (clip, (int) engine.getClips (track).size()))
        return;

    auto clips = engine.getClips (track);
    clips[(size_t) clip].loopsToNext = shouldLoop;
    applyClipEdit (track, clips, shouldLoop ? "Loop Until Next Part" : "Stop Looping");
}

void Studio::setPartHalfTime (int track, int part, bool halfTime)
{
    if (! isDrums (track) || ! canEdit() || ! juce::isPositiveAndBelow (part, (int) engine.getDrumParts (track).size()))
        return;

    auto parts = engine.getDrumParts (track);
    parts[(size_t) part].halfTime = halfTime;
    applyDrumEdit (track, parts, halfTime ? "Half Time" : "Normal Time");
}

void Studio::quantizeClip (int track, int clip, int gridTicks)
{
    if (! canEdit() || engine.getTrackType (track) != TrackType::midi)
        return;

    if (const auto clips = engine.quantizeClip (track, clip, gridTicks); clips != engine.getClips (track))
        applyClipEdit (track, clips, "Quantize");
    else
        postMessage ("Couldn't quantize that clip.");
}

bool Studio::isDrums (int track) const
{
    return engine.getTrackType (track) == TrackType::drums;
}

double Studio::getSamplesPerBar() const
{
    return getSamplesPerBeat() * beatsPerBar;
}

DrumPartList Studio::previewPartDrag (int track, int part, DragZone zone, juce::int64 distance) const
{
    const auto& parts = engine.getDrumParts (track);

    if (! juce::isPositiveAndBelow (part, (int) parts.size()))
        return parts;

    const auto bars = juce::roundToInt ((double) distance / getSamplesPerBar());
    return dragPart (parts, part, zone, bars, (int) engine.getLoopEnd (track, part));
}

juce::Result Studio::addPart (int track, const juce::String& grooveId, juce::int64 position)
{
    if (! isDrums (track))
        return juce::Result::fail ("Grooves go on drum tracks.");

    if (const auto drums = engine.loadDrums(); drums.failed())
        return drums;

    const auto* groove = engine.getGrooves().find (grooveId);

    if (groove == nullptr)
        return juce::Result::fail ("That groove isn't in the library.");

    if (engine.getState() != TransportState::stopped)
        return juce::Result::fail ("Stop the transport to edit.");

    const auto bar = juce::jmax (0, (int) std::floor ((double) position / getSamplesPerBar()));
    auto parts = engine.getDrumParts (track);
    parts.push_back ({ groove->id, bar, groove->bars, 0 });
    applyDrumEdit (track, parts, groove->isFill ? "Add Fill" : "Add Groove");
    return juce::Result::ok();
}

void Studio::startGroovePreview (int track, const juce::String& grooveId)
{
    if (isDrums (track) && engine.loadDrums().wasOk())
        engine.startGroovePreview (track, grooveId);
}

void Studio::stopGroovePreview()
{
    engine.stopGroovePreview();
}

juce::Array<juce::File> Studio::findTakes (int track) const
{
    auto takes = currentSession.findChildFiles (juce::File::findFiles, false,
                                                engine.getTrackType (track) == TrackType::midi ? "*.mid" : "*.wav");
    takes.sort();
    return takes;
}

void Studio::addTakeAtPlayhead (int track, const juce::File& file)
{
    if (! canEdit())
        return;

    Clip clip;
    clip.file = file;
    clip.timelineStart = toClipUnits (track, engine.getPosition());

    if (engine.getTrackType (track) == TrackType::midi)
    {
        const auto take = engine.loadMidiTake (file);

        if (take == nullptr)
            return;

        clip.length = take->length;
    }
    else
    {
        juce::AudioFormatManager formats;
        formats.registerBasicFormats();
        const std::unique_ptr<juce::AudioFormatReader> reader (formats.createReaderFor (file));

        if (reader == nullptr)
            return;

        clip.length = reader->lengthInSamples;
    }

    clip.fileLength = clip.length;

    auto clips = engine.getClips (track);
    clips.push_back (clip);
    applyClipEdit (track, clips, "Add Take");
}

//==============================================================================
void Studio::setCycleEnabled (bool shouldCycle)
{
    // Turned on with nowhere to go round, it takes the four bars from the playhead's bar.
    if (shouldCycle && engine.getCycleRange().getLength() < AudioEngine::minimumCycleSamples)
    {
        const auto samplesPerBar = getSamplesPerBeat() * beatsPerBar;
        const auto bar = std::floor ((double) engine.getPosition() / samplesPerBar);
        engine.setCycleRange ({ (juce::int64) std::llround (bar * samplesPerBar), (juce::int64) std::llround ((bar + 4.0) * samplesPerBar) });
    }

    engine.setCycleEnabled (shouldCycle);
    changed();
    saveSession();
}

void Studio::setCycleRange (juce::Range<juce::int64> range)
{
    // Marking a range is asking to go round it.
    engine.setCycleRange (range);
    setCycleEnabled (true);
}

void Studio::clearCycle()
{
    engine.setCycleEnabled (false);
    engine.setCycleRange ({});
    changed();
    saveSession();
}

//==============================================================================
double Studio::importRate() const
{
    const auto sessionRate = engine.getSessionSampleRate();
    return sessionRate > 0.0 ? sessionRate : getTimelineRate();
}

juce::File Studio::importDestinationFor (const juce::File& source) const
{
    currentSession.createDirectory();
    return currentSession.getNonexistentChildFile (juce::File::createLegalFileName (source.getFileNameWithoutExtension()), ".wav", false);
}

juce::Result Studio::convertAudioFile (const juce::File& source, const juce::File& destination, double sampleRate)
{
    juce::AudioFormatManager formats;
    formats.registerBasicFormats();

    const std::unique_ptr<juce::AudioFormatReader> reader (formats.createReaderFor (source));

    if (reader == nullptr)
        return juce::Result::fail ("Couldn't read " + source.getFileName() + " as audio.");

    // Read whole into memory: a song-length stereo file is tens of megabytes.
    constexpr juce::int64 longest = 60 * 60 * 192000;

    if (reader->lengthInSamples <= 0 || reader->lengthInSamples > longest || reader->sampleRate <= 0.0)
        return juce::Result::fail ("Couldn't import " + source.getFileName() + ": it's empty or too long.");

    const auto inputChannels = (int) reader->numChannels;
    const auto outputChannels = inputChannels > 1 ? 2 : 1;
    const auto length = (int) reader->lengthInSamples;

    juce::AudioBuffer<float> input (inputChannels, length);
    reader->read (&input, 0, length, 0, true, true);

    // The resampler looks this far ahead, so the input gets silence after it.
    const auto ratio = reader->sampleRate / sampleRate;
    const auto latency = (double) juce::Interpolators::WindowedSinc::getBaseLatency();
    const auto padding = (int) std::ceil (2.0 * latency * juce::jmax (1.0, ratio)) + 256;

    // More than two channels fold down: even ones to the left, odd ones to the right.
    juce::AudioBuffer<float> folded (outputChannels, length + padding);
    folded.clear();

    if (inputChannels <= 2)
    {
        for (int channel = 0; channel < outputChannels; ++channel)
            folded.copyFrom (channel, 0, input, channel, 0, length);
    }
    else
    {
        for (int channel = 0; channel < inputChannels; ++channel)
            folded.addFrom (channel % 2, 0, input, channel, 0, length, 2.0f / (float) inputChannels);
    }

    juce::AudioBuffer<float> output;

    if (std::abs (ratio - 1.0) < 1.0e-9)
    {
        output.setSize (outputChannels, length);

        for (int channel = 0; channel < outputChannels; ++channel)
            output.copyFrom (channel, 0, folded, channel, 0, length);
    }
    else
    {
        // The resampler's output runs late by its latency, so that much is made and dropped.
        const auto outputLength = (int) std::llround ((double) length / ratio);
        const auto skip = (int) std::llround (latency / ratio);
        juce::HeapBlock<float> scratch ((size_t) (outputLength + skip));
        output.setSize (outputChannels, outputLength);

        for (int channel = 0; channel < outputChannels; ++channel)
        {
            juce::Interpolators::WindowedSinc resampler;
            resampler.process (ratio, folded.getReadPointer (channel), scratch.get(), outputLength + skip);
            output.copyFrom (channel, 0, scratch.get() + skip, outputLength);
        }
    }

    // Deleted first, because an output stream adds to the end of a file that's there.
    destination.deleteFile();
    std::unique_ptr<juce::OutputStream> stream = destination.createOutputStream();

    if (stream == nullptr)
        return juce::Result::fail ("Couldn't write " + destination.getFullPathName());

    juce::WavAudioFormat wav;

    const auto options = juce::AudioFormatWriterOptions().withSampleRate (sampleRate)
                                                         .withNumChannels (outputChannels)
                                                         .withBitsPerSample (24);
    const auto writer = wav.createWriterFor (stream, options);

    if (writer == nullptr || ! writer->writeFromAudioSampleBuffer (output, 0, output.getNumSamples()))
        return juce::Result::fail ("Couldn't write " + destination.getFullPathName());

    return juce::Result::ok();
}

juce::Result Studio::placeImportedTake (const juce::File& take, int track, juce::int64 position, const juce::String& trackName)
{
    if (engine.getState() != TransportState::stopped)
        return juce::Result::fail ("Stop the transport, then drop " + trackName + " again.");

    juce::AudioFormatManager formats;
    formats.registerBasicFormats();
    const std::unique_ptr<juce::AudioFormatReader> reader (formats.createReaderFor (take));

    if (reader == nullptr)
        return juce::Result::fail ("Couldn't read the imported copy of " + trackName + ".");

    if (track < 0 || ! engine.isTrackActive (track) || engine.getTrackType (track) != TrackType::audio)
    {
        track = engine.addTrack (nextTrackName (trackName), TrackType::audio);

        if (track < 0)
            return juce::Result::fail ("A session can have up to " + juce::String (maxTracks) + " tracks.");
    }

    // The first take sets the session's rate, as a recording would.
    if (engine.getSessionSampleRate() <= 0.0)
        engine.setSessionSampleRate (reader->sampleRate);

    Clip clip;
    clip.file = take;
    clip.timelineStart = juce::jmax ((juce::int64) 0, position);
    clip.length = reader->lengthInSamples;
    clip.fileLength = reader->lengthInSamples;

    auto clips = engine.getClips (track);
    clips.push_back (clip);
    applyClipEdit (track, clips, "Import Audio");
    return juce::Result::ok();
}

juce::Result Studio::importAudioNow (const juce::File& source, int track, juce::int64 position)
{
    const auto destination = importDestinationFor (source);

    if (const auto result = convertAudioFile (source, destination, importRate()); result.failed())
    {
        destination.deleteFile();
        postMessage (result.getErrorMessage(), true);
        return result;
    }

    const auto result = placeImportedTake (destination, track, position, source.getFileNameWithoutExtension());

    if (result.failed())
        postMessage (result.getErrorMessage(), true);

    return result;
}

void Studio::importAudio (const juce::File& source, int track, juce::int64 position)
{
    const auto destination = importDestinationFor (source);
    const auto rate = importRate();

    // Claimed now, so files dropped together don't pick the same name.
    destination.create();
    postMessage ("Importing " + source.getFileName() + "...");

    importThread.addJob ([weakThis = juce::WeakReference<Studio> (this), source, destination, rate, track, position]
                         {
                             const auto converted = convertAudioFile (source, destination, rate);

                             juce::MessageManager::callAsync ([weakThis, converted, source, destination, track, position]
                                                              {
                                                                  if (weakThis == nullptr)
                                                                      return;

                                                                  auto result = converted;

                                                                  if (result.wasOk())
                                                                      result = weakThis->placeImportedTake (destination, track, position,
                                                                                                            source.getFileNameWithoutExtension());

                                                                  if (result.wasOk())
                                                                  {
                                                                      weakThis->postMessage ("Imported " + source.getFileName() + ".");
                                                                  }
                                                                  else
                                                                  {
                                                                      destination.deleteFile();
                                                                      weakThis->postMessage (result.getErrorMessage(), true);
                                                                  }
                                                              });
                         });
}

//==============================================================================
void Studio::applyClipEdit (int track, const ClipList& clips, const juce::String& editName)
{
    if (engine.getState() != TransportState::stopped)
    {
        postMessage ("Stop the transport to edit.");
        return;
    }

    undoManager.beginNewTransaction (editName);
    undoManager.perform (new ClipEdit (engine, track, engine.getClips (track), clips));
    changed();
    saveSession();
}

void Studio::applyDrumEdit (int track, const DrumPartList& parts, const juce::String& editName)
{
    if (engine.getState() != TransportState::stopped)
    {
        postMessage ("Stop the transport to edit.");
        return;
    }

    undoManager.beginNewTransaction (editName);
    undoManager.perform (new DrumEdit (engine, track, engine.getDrumParts (track), parts));
    changed();
    saveSession();
}

void Studio::undo()
{
    if (engine.getState() != TransportState::stopped)
    {
        postMessage ("Stop the transport to undo.");
        return;
    }

    undoManager.undo();
    changed();
    saveSession();
}

void Studio::redo()
{
    if (engine.getState() != TransportState::stopped)
    {
        postMessage ("Stop the transport to redo.");
        return;
    }

    undoManager.redo();
    changed();
    saveSession();
}

//==============================================================================
juce::File Studio::insertsFile() const
{
    return currentSession.getChildFile ("inserts.xml");
}

void Studio::startPluginScan()
{
    const auto executable = paths.scanExecutable.getFullPathName();

    const auto command = [executable] (const PluginScanTarget& target, const juce::File& resultFile)
    {
        return juce::StringArray { executable, scanChildArgument, target.format, target.identifier, resultFile.getFullPathName() };
    };

    const auto workDirectory = juce::File::getSpecialLocation (juce::File::tempDirectory).getChildFile ("RoughTrackSwiftScan");
    const auto weakThis = juce::WeakReference<Studio> (this);

    pluginLibrary->startScan (command,
                              workDirectory,
                              [weakThis] (const juce::String& message)
                              {
                                  if (weakThis != nullptr)
                                      weakThis->postMessage (message);
                              },
                              [weakThis] (const PluginScanResult& result)
                              {
                                  if (weakThis == nullptr)
                                      return;

                                  juce::String message;
                                  message << (int) weakThis->pluginLibrary->getPlugins().size() << " effects available.";

                                  if (! result.failures.empty())
                                  {
                                      message << " " << (int) result.failures.size() << " failed: ";

                                      for (const auto& failure : result.failures)
                                          message << juce::File::createFileWithoutCheckingPath (failure.target.identifier).getFileName()
                                                  << " (" << failure.reason << ") ";
                                  }

                                  weakThis->postMessage (message);
                                  weakThis->changed();
                              });
}

bool Studio::canChangeInserts()
{
    if (engine.getState() == TransportState::stopped)
        return true;

    postMessage ("Stop the transport to change plugins.");
    return false;
}

void Studio::restoreInserts()
{
    const auto xml = juce::parseXML (insertsFile());

    if (xml == nullptr)
        return;

    const auto inserts = parseSavedInserts (*xml);
    numInsertsRestoring = (int) inserts.size();

    // A track holding only a plugin wasn't saved as in use by older sessions.
    for (const auto& insert : inserts)
    {
        if (! engine.isTrackActive (insert.track))
        {
            const auto isLegacyTrack = insert.track < (int) legacyTrackNames.size();
            engine.activateTrack (insert.track, isLegacyTrack ? legacyTrackNames[(size_t) insert.track] : "Audio");
        }

        loadInsert (insert.track, insert.slot, insert);
    }
}

void Studio::loadInsert (int track, int slot, const SavedInsert& insert)
{
    postMessage ("Loading " + insert.description.name + "...");

    const auto sampleRate = engine.getSampleRate() > 0.0 ? engine.getSampleRate() : preferredSampleRate;
    auto* device = deviceManager.getCurrentAudioDevice();
    const auto blockSize = device != nullptr ? device->getCurrentBufferSizeSamples() : preferredBufferSize;

    pluginLibrary->createInstance (insert.description,
                                   sampleRate,
                                   blockSize,
                                   [weakThis = juce::WeakReference<Studio> (this), track, slot, insert] (std::unique_ptr<juce::AudioPluginInstance> instance,
                                                                                                         const juce::String& error)
                                   {
                                       if (weakThis == nullptr)
                                           return;

                                       auto& self = *weakThis;
                                       const auto wasRestoring = self.numInsertsRestoring > 0;
                                       auto failure = instance == nullptr ? (error.isNotEmpty() ? error : juce::String ("It didn't load."))
                                                                          : juce::String();

                                       if (failure.isEmpty() && ! self.canChangeInserts())
                                           failure = "Stop the transport to change plugins.";

                                       if (failure.isEmpty())
                                       {
                                           self.closeEditors (track, slot);
                                           failure = self.engine.setInsert (track, slot, std::move (instance), insert.state).getErrorMessage();
                                       }

                                       if (failure.isEmpty())
                                       {
                                           self.engine.setInsertBypassed (track, slot, insert.bypassed);
                                           self.engine.setInsertBeforeAmp (track, slot, insert.beforeAmp);
                                           self.postMessage (insert.description.name + " loaded, latency "
                                                             + juce::String (self.engine.getInsert (track, slot)->getLatencySamples()) + " samples.");
                                       }
                                       else
                                       {
                                           self.insertsNeedKeeping = self.insertsNeedKeeping || wasRestoring;
                                           self.postMessage ("Couldn't load " + insert.description.name + ": " + failure, true);
                                       }

                                       if (wasRestoring)
                                           --self.numInsertsRestoring;

                                       self.changed();
                                       self.saveInserts();
                                   });
}

// A plugin that's missing today might be back tomorrow, so its saved settings
// are kept rather than overwritten by a session that couldn't load it.
void Studio::saveInserts()
{
    if (! sessionLoaded || numInsertsRestoring > 0 || insertsNeedKeeping)
        return;

    insertsFile().getParentDirectory().createDirectory();

    if (const auto xml = engine.createInsertsXml())
        insertsFile().replaceWithText (xml->toString());
}

//==============================================================================
void Studio::changed()
{
    ++revision;
}

void Studio::postMessage (const juce::String& text, bool isWarning)
{
    messages.push_back ({ text, isWarning || text.startsWith ("Couldn't") });

    while (messages.size() > 50)
        messages.pop_front();
}

std::vector<StudioMessage> Studio::takeMessages()
{
    std::vector<StudioMessage> taken (messages.begin(), messages.end());
    messages.clear();
    return taken;
}

void Studio::tick()
{
    if (recordingInProgress && engine.getState() == TransportState::stopped)
        recordingFinished();

    if (--autosaveCountdown <= 0)
    {
        autosaveCountdown = autosaveTicks;
        saveSession();

        if (audioStarted)
            restoreChosenAudioDevice();
    }

    // Once a day for each version, a while after starting, and only with a device open
    // (not in tests).
    if (audioStarted && ! automaticUpdateCheckDone)
    {
        automaticUpdateCheckDone = true;
        const auto now = juce::Time::currentTimeMillis();

        if (checksForUpdatesAutomatically() && updates::isUpdateCheckingAvailable()
            && updates::isAutomaticCheckDue (settings->getValue (updates::lastCheckKey), ROUGHTRACK_VERSION, now))
        {
            settings->setValue (updates::lastCheckKey, updates::lastCheckRecord (ROUGHTRACK_VERSION, now));
            checkForUpdates (false);
        }
    }

    handleControlEvents();
    showControllerLights();
    updateTuner (1.0 / timerHz);
    finishMixdown();

    if (calibrating && engine.isCalibrationFinished())
    {
        calibrating = false;
        const auto result = engine.finishCalibration();

        if (result.succeeded)
            settings->setValue (latencyKey(), result.latencySamples);

        calibrationResult = result;
        changed();
    }

    if (updateThread.joinable() && ! updateRunning.load())
    {
        updateThread.join();

        const auto offered = updateWork.release.has_value()
                             && updates::shouldOffer (*updateWork.release, ROUGHTRACK_VERSION, settings->getValue ("skippedVersion"), updateWork.isManual);

        if (offered || updateWork.isManual)
        {
            auto outcome = updateWork;

            if (! offered)
                outcome.release.reset();

            updateOutcome = outcome;
        }
    }

    if (const auto rateWarning = engine.getSampleRateWarning(); rateWarning != lastRateWarning)
    {
        lastRateWarning = rateWarning;

        if (rateWarning.isNotEmpty())
            postMessage (rateWarning, true);
    }
}

} // namespace roughtrack

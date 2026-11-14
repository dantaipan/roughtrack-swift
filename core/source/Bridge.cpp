#include "RoughTrackCore.h"

#include "roughtrack/AudioDevices.h"
#include "roughtrack/Midi.h"
#include "roughtrack/PluginScanner.h"
#include "roughtrack/Studio.h"

#include <juce_audio_formats/juce_audio_formats.h>

#include <map>

namespace
{

std::unique_ptr<juce::ScopedJuceInitialiser_GUI> juceInitialiser;
std::unique_ptr<roughtrack::Studio> studio;
rt::App theApp;

/** Takes are summarised once, a peak per this many samples, and drawn from that. */
constexpr int samplesPerSummaryPoint = 256;

roughtrack::Studio& get()
{
    jassert (studio != nullptr);
    return *studio;
}

double timelineRate()
{
    return get().getTimelineRate();
}

std::string toStd (const juce::String& text)
{
    return text.toStdString();
}

juce::String fromStd (const std::string& text)
{
    return juce::String::fromUTF8 (text.c_str());
}

rt::Tone3000Source tone3000Source (const roughtrack::FileSource& source)
{
    rt::Tone3000Source info;

    if (source.isValid())
    {
        info.toneId = source.toneId;
        info.title = toStd (source.title);
        info.model = toStd (source.model);
        info.creator = toStd (source.creator);
    }

    return info;
}

rt::Tone3000Tone tone3000Tone (const rs::t3k::Tone& tone)
{
    rt::Tone3000Tone info;
    info.id = tone.id;
    info.title = toStd (tone.title);
    info.creator = toStd (tone.creator.name());
    info.gear = toStd (rs::t3k::gearName (tone.gear));
    info.format = toStd (rs::t3k::formatName (tone.format));
    info.license = toStd (tone.license);
    info.description = toStd (tone.description);
    info.url = toStd (tone.url);
    info.imageUrl = toStd (tone.image());
    info.isIr = tone.isIr();
    return info;
}

roughtrack::Tone3000Target tone3000Target (rt::Tone3000Target target)
{
    return target == rt::Tone3000Target::amp ? roughtrack::Tone3000Target::amp : roughtrack::Tone3000Target::cabinet;
}

/** The lists mix every format; for a cabinet, TONE3000 can narrow them to cabs. */
juce::String tone3000Gear (rt::Tone3000Target target)
{
    return target == rt::Tone3000Target::cabinet ? "cab" : "";
}

/** Peaks of every take drawn so far, by file. */
class WaveformCache
{
public:
    const std::vector<float>& summary (const juce::File& file)
    {
        const auto key = file.getFullPathName().toStdString();

        if (const auto found = summaries.find (key); found != summaries.end())
            return found->second;

        auto& points = summaries[key];

        if (formats.getNumKnownFormats() == 0)
            formats.registerBasicFormats();

        if (const std::unique_ptr<juce::AudioFormatReader> reader (formats.createReaderFor (file)); reader != nullptr)
        {
            const auto numChannels = (int) reader->numChannels;
            juce::AudioBuffer<float> block (numChannels, samplesPerSummaryPoint);
            points.reserve ((size_t) (reader->lengthInSamples / samplesPerSummaryPoint + 1));

            for (juce::int64 start = 0; start < reader->lengthInSamples; start += samplesPerSummaryPoint)
            {
                const auto count = (int) juce::jmin ((juce::int64) samplesPerSummaryPoint, reader->lengthInSamples - start);
                reader->read (&block, 0, count, start, true, true);

                auto peak = 0.0f;

                for (int channel = 0; channel < numChannels; ++channel)
                    peak = juce::jmax (peak, block.getMagnitude (channel, 0, count));

                points.push_back (peak);
            }
        }

        return points;
    }

private:
    juce::AudioFormatManager formats;
    std::map<std::string, std::vector<float>> summaries;
};

/** A track's clips as Swift sees them, in samples whatever the track's units. */
std::vector<rt::ClipInfo> describeClips (int track, const roughtrack::ClipList& clips)
{
    const auto& owner = get();
    const auto& engine = owner.getEngine();
    const auto isMidi = engine.getTrackType (track) == roughtrack::TrackType::midi;
    const auto toSamples = [&owner, track] (juce::int64 units) { return (std::int64_t) owner.toSamples (track, units); };
    const auto isEngineList = &clips == &engine.getClips (track);

    std::vector<rt::ClipInfo> infos;
    int index = 0;

    for (const auto& clip : clips)
    {
        rt::ClipInfo info;
        info.index = index;
        info.isMidi = isMidi;
        info.start = toSamples (clip.timelineStart);
        info.length = toSamples (clip.length);
        info.fadeIn = toSamples (clip.fadeIn);
        info.fadeOut = toSamples (clip.fadeOut);
        info.name = clip.file.getFileNameWithoutExtension().toStdString();
        info.looping = clip.loopsToNext;

        // A preview's loops aren't worked out, so they show to their own end until it lands.
        info.loopEnd = clip.loopsToNext && isEngineList ? toSamples (engine.getLoopEnd (track, index)) : toSamples (clip.timelineEnd());

        info.file = clip.file.getFullPathName().toStdString();
        info.fileOffset = toSamples (clip.fileOffset);

        infos.push_back (info);
        ++index;
    }

    return infos;
}

/** A drum track's parts as Swift sees them, in samples like clips. */
std::vector<rt::ClipInfo> describeParts (int track, const roughtrack::DrumPartList& parts)
{
    auto& owner = get();
    auto& engine = owner.getEngine();
    const auto samplesPerBar = owner.getSamplesPerBar();
    const auto toSamples = [samplesPerBar] (int bars) { return (std::int64_t) std::llround (bars * samplesPerBar); };
    const auto isEngineList = &parts == &engine.getDrumParts (track);

    std::vector<rt::ClipInfo> infos;
    int index = 0;

    for (const auto& part : parts)
    {
        const auto* groove = engine.getGrooves().find (part.groove);
        const auto loopEnd = part.loopsToNext && isEngineList ? juce::jmax (part.endBar(), (int) engine.getLoopEnd (track, index)) : part.endBar();

        rt::ClipInfo info;
        info.index = index;
        info.start = toSamples (part.startBar);
        info.length = toSamples (part.bars);
        info.looping = part.loopsToNext;
        info.loopEnd = toSamples (loopEnd);
        info.groove = toStd (part.groove);
        info.offsetBars = part.offsetBars;
        info.bars = part.bars;
        info.loopBars = loopEnd - part.startBar;
        info.grooveMissing = groove == nullptr;
        info.isFill = groove != nullptr && groove->isFill;
        info.name = groove == nullptr ? std::string ("Missing groove")
                                      : toStd (groove->style + " " + (groove->isFill ? "fill " : "") + groove->name);
        infos.push_back (info);
        ++index;
    }

    return infos;
}

/** Where a piece is drawn in a part, from the kick at the bottom to the cymbals at the top. */
int drawingRow (roughtrack::DrumPiece piece)
{
    using roughtrack::DrumPiece;

    switch (piece)
    {
        case DrumPiece::kick:        return 0;
        case DrumPiece::snare:
        case DrumPiece::sideStick:   return 1;
        case DrumPiece::tomHigh:
        case DrumPiece::tomMid:
        case DrumPiece::tomLow:      return 2;
        case DrumPiece::hiHatClosed:
        case DrumPiece::hiHatOpen:
        case DrumPiece::hiHatPedal:  return 3;
        case DrumPiece::crash:
        case DrumPiece::crash2:
        case DrumPiece::ride:
        case DrumPiece::rideBell:
        case DrumPiece::count:       break;
    }

    return 4;
}

WaveformCache waveforms;

} // namespace

namespace rt
{

//==============================================================================
std::string App::sessionName() const
{
    return get().getCurrentSession().getFileName().toStdString();
}

std::vector<std::string> App::sessions() const
{
    std::vector<std::string> names;

    for (const auto& folder : get().listSessions())
        names.push_back (folder.getFileName().toStdString());

    return names;
}

void App::openSession (const std::string& name)
{
    get().openSession (get().getCurrentSession().getSiblingFile (name));
}

std::string App::newSession (const std::string& name)
{
    return get().newSession (name).getErrorMessage().toStdString();
}

std::uint32_t App::revision() const
{
    return get().getRevision();
}

std::vector<TrackInfo> App::tracks() const
{
    const auto& engine = get().getEngine();
    std::vector<TrackInfo> infos;

    for (const auto track : engine.getTrackOrder())
    {
        const auto settings = engine.getTrackSettings (track);

        TrackInfo info;
        info.id = track;
        info.name = engine.getTrackName (track).toStdString();
        info.kind = (TrackKind) engine.getTrackType (track);
        info.muted = settings.muted;
        info.soloed = settings.soloed;
        info.armed = engine.isTrackArmed (track);
        info.monitoring = settings.monitoring;
        info.gain = settings.gain;
        info.pan = settings.pan;
        info.inverted = settings.inverted;
        info.firstInput = settings.firstInput;
        info.inputChannels = settings.inputChannels;

        const auto& channel = engine.getChannel (track);
        info.ampName = channel.getAmpFile() == juce::File() ? std::string() : toStd (channel.getAmpFile().getFileNameWithoutExtension());
        info.cabinetName = channel.getCabinetFile() == juce::File() ? std::string() : toStd (channel.getCabinetFile().getFileNameWithoutExtension());
        info.ampTone3000 = tone3000Source (channel.getAmpSource());
        info.cabinetTone3000 = tone3000Source (channel.getCabinetSource());

        if (auto* tone3000 = get().getTone3000())
        {
            info.ampLoading = tone3000->isLoading (track, roughtrack::Tone3000Target::amp);
            info.cabinetLoading = tone3000->isLoading (track, roughtrack::Tone3000Target::cabinet);
        }

        infos.push_back (info);
    }

    return infos;
}

std::vector<ClipInfo> App::clips (int track) const
{
    const auto& engine = get().getEngine();

    if (engine.getTrackType (track) != roughtrack::TrackType::drums)
        return describeClips (track, engine.getClips (track));

    return describeParts (track, engine.getDrumParts (track));
}

std::vector<float> App::waveform (const std::string& file, std::int64_t offset, std::int64_t length, int numPoints) const
{
    std::vector<float> points ((size_t) juce::jmax (0, numPoints), 0.0f);
    const auto& summary = waveforms.summary (juce::File (file));

    if (summary.empty() || numPoints <= 0 || length <= 0)
        return points;

    for (int i = 0; i < numPoints; ++i)
    {
        const auto from = (offset + length * i / numPoints) / samplesPerSummaryPoint;
        const auto to = juce::jmax (from + 1, (offset + length * (i + 1) / numPoints) / samplesPerSummaryPoint);

        auto peak = 0.0f;

        for (auto point = juce::jmax ((std::int64_t) 0, from); point < juce::jmin ((std::int64_t) summary.size(), to); ++point)
            peak = juce::jmax (peak, summary[(size_t) point]);

        points[(size_t) i] = peak;
    }

    return points;
}

//==============================================================================
std::vector<ClipInfo> App::previewDrag (int track, int clip, DragZone zone, std::int64_t distance, bool placeFreely) const
{
    if (get().getEngine().getTrackType (track) == roughtrack::TrackType::drums)
        return describeParts (track, get().previewPartDrag (track, clip, (roughtrack::DragZone) zone, distance));

    return describeClips (track, get().previewDrag (track, clip, (roughtrack::DragZone) zone, distance, placeFreely));
}

void App::commitDrag (int track, int clip, DragZone zone, std::int64_t distance, bool placeFreely)
{
    get().commitDrag (track, clip, (roughtrack::DragZone) zone, distance, placeFreely);
}

void App::splitClip (int track, int clip, std::int64_t position, bool placeFreely) { get().splitClip (track, clip, position, placeFreely); }
void App::deleteClip (int track, int clip)                                         { get().deleteClip (track, clip); }
void App::setClipLooping (int track, int clip, bool value)                         { get().setClipLooping (track, clip, value); }
void App::quantizeClip (int track, int clip, int gridTicks)                        { get().quantizeClip (track, clip, gridTicks); }

std::vector<NoteInfo> App::midiNotes (int track, const std::string& file, std::int64_t offset, std::int64_t length) const
{
    std::vector<NoteInfo> notes;
    const auto& owner = get();
    const auto* take = owner.getEngine().findMidiTake (juce::File (juce::String::fromUTF8 (file.c_str())));

    if (take == nullptr || length <= 0)
        return notes;

    const auto from = owner.toClipUnits (track, offset);
    const auto to = owner.toClipUnits (track, offset + length);

    for (const auto& note : take->notes)
    {
        if (note.tick + note.length <= from || note.tick >= to)
            continue;

        NoteInfo info;
        info.start = owner.toSamples (track, note.tick - from);
        info.length = owner.toSamples (track, note.length);
        info.pitch = note.pitch;
        info.velocity = note.velocity;
        notes.push_back (info);
    }

    return notes;
}

std::vector<GrooveInfo> App::grooves() const
{
    std::vector<GrooveInfo> infos;
    auto& engine = get().getEngine();

    if (engine.loadDrums().failed())
        return infos;

    for (const auto& groove : engine.getGrooves().getGrooves())
    {
        GrooveInfo info;
        info.id = toStd (groove.id);
        info.style = toStd (groove.style);
        info.name = toStd (groove.name);
        info.isFill = groove.isFill;
        info.bars = groove.bars;
        info.recordedBpm = groove.recordedBpm;
        info.nearTempo = roughtrack::isNearTempo (groove, engine.getTempo());
        infos.push_back (info);
    }

    return infos;
}

std::vector<DrumHitInfo> App::grooveHits (const std::string& id, int offsetBars, int bars) const
{
    std::vector<DrumHitInfo> hits;
    const auto* groove = get().getEngine().getGrooves().find (juce::String::fromUTF8 (id.c_str()));

    if (groove == nullptr || groove->bars <= 0 || (int) groove->barStarts.size() <= groove->bars)
        return hits;

    for (int bar = 0; bar < bars; ++bar)
    {
        const auto barInGroove = juce::negativeAwareModulo (bar + offsetBars, groove->bars);

        for (auto i = groove->barStarts[(size_t) barInGroove]; i < groove->barStarts[(size_t) barInGroove + 1]; ++i)
        {
            const auto& hit = groove->hits[(size_t) i];
            hits.push_back ({ bar * roughtrack::beatsPerBar + hit.beat - barInGroove * roughtrack::beatsPerBar,
                              drawingRow (hit.piece), hit.velocity });
        }
    }

    return hits;
}

std::string App::addPart (int track, const std::string& groove, std::int64_t position)
{
    return toStd (get().addPart (track, juce::String::fromUTF8 (groove.c_str()), position).getErrorMessage());
}

void App::startGroovePreview (int track, const std::string& groove)
{
    get().startGroovePreview (track, juce::String::fromUTF8 (groove.c_str()));
}

void App::stopGroovePreview()          { get().stopGroovePreview(); }
bool App::isPreviewingGroove() const   { return get().getEngine().isPreviewingGroove(); }

void App::startTuner()  { get().startTuner(); }
void App::stopTuner()   { get().stopTuner(); }

TunerInfo App::tuner() const
{
    const auto display = get().getTunerDisplay();
    TunerInfo info;
    info.running = get().isTunerRunning();
    info.hasNote = display.hasNote;
    info.note = toStd (display.note);
    info.cents = display.cents;
    info.source = toStd (display.source);
    return info;
}

std::string App::startCalibration()   { return toStd (get().startCalibration().getErrorMessage()); }
bool App::isCalibrating() const       { return get().isCalibrating(); }

CalibrationInfo App::takeCalibrationResult()
{
    CalibrationInfo info;

    if (const auto result = get().takeCalibrationResult())
    {
        info.ready = true;
        info.succeeded = result->succeeded;
        info.latencySamples = result->latencySamples;
        info.latencyMs = roughtrack::bufferLatencyMs (result->latencySamples, timelineRate());
        info.message = toStd (result->message);
    }

    return info;
}

double App::calibratedLatencyMs() const
{
    const auto samples = get().getCalibratedLatency();
    return samples < 0 ? -1.0 : roughtrack::bufferLatencyMs (samples, timelineRate());
}

std::string App::controllerName() const     { return toStd (get().getControllerName()); }
bool App::controllerAutomatic() const       { return get().isControllerAutomatic(); }
int App::controllerBank() const             { return get().getControllerBank(); }
void App::chooseControllerAutomatically()   { get().chooseControllerAutomatically(); }

void App::chooseController (const std::string& portName)
{
    get().chooseController (juce::String::fromUTF8 (portName.c_str()));
}

std::vector<std::string> App::midiInputNames() const
{
    std::vector<std::string> names;

    for (const auto& name : get().getMidiInputNames())
        names.push_back (toStd (name));

    return names;
}

std::string App::startMixdown (const std::string& path, bool stems)
{
    return toStd (get().startMixdown (juce::File (juce::String::fromUTF8 (path.c_str())), stems).getErrorMessage());
}

bool App::isMixingDown() const          { return get().isMixingDown(); }
double App::mixdownProgress() const     { return get().getMixdownProgress(); }
void App::cancelMixdown()               { get().cancelMixdown(); }
std::string App::mixdownFolder() const  { return toStd (get().getMixdownFolder().getFullPathName()); }
std::string App::nextStemsFolder() const { return toStd (get().getNextStemsFolder().getFullPathName()); }

MixdownInfo App::takeMixdownOutcome()
{
    MixdownInfo info;

    if (const auto outcome = get().takeMixdownOutcome())
    {
        info.ready = true;
        info.succeeded = outcome->result.result.wasOk();
        info.message = toStd (outcome->result.result.getErrorMessage());
        info.path = toStd (outcome->file.getFullPathName());
        info.stems = outcome->stems;
        info.seconds = outcome->seconds;
        info.peakDecibels = juce::Decibels::gainToDecibels (outcome->result.peak, -100.0f);

        // A float mix can go over full scale, but the 24-bit file can't hold it.
        info.clipped = outcome->result.peak >= 1.0f;
        info.numStems = outcome->numStems;
    }

    return info;
}

std::string App::version() const                { return ROUGHTRACK_VERSION; }
bool App::updateCheckingAvailable() const       { return updates::isUpdateCheckingAvailable(); }
void App::checkForUpdates (bool manual)         { get().checkForUpdates (manual); }
void App::skipUpdate (const std::string& value) { get().skipUpdate (juce::String::fromUTF8 (value.c_str())); }
bool App::checksForUpdatesAutomatically() const { return get().checksForUpdatesAutomatically(); }
void App::setChecksForUpdatesAutomatically (bool value) { get().setChecksForUpdatesAutomatically (value); }

UpdateInfo App::takeUpdateOutcome()
{
    UpdateInfo info;

    if (const auto outcome = get().takeUpdateOutcome())
    {
        info.ready = true;
        info.manual = outcome->isManual;
        info.error = toStd (outcome->error);

        if (outcome->release.has_value())
        {
            info.hasRelease = true;
            info.version = toStd (outcome->release->version);
            info.notes = toStd (updates::runsToText (updates::notesToRuns (outcome->release->notes)));
            info.pageUrl = toStd (outcome->release->pageUrl);
            info.downloadUrl = toStd (outcome->release->downloadUrl);
        }
    }

    return info;
}

std::vector<std::string> App::takes (int track) const
{
    std::vector<std::string> paths;

    for (const auto& file : get().findTakes (track))
        paths.push_back (toStd (file.getFullPathName()));

    return paths;
}

void App::addTakeAtPlayhead (int track, const std::string& file)
{
    get().addTakeAtPlayhead (track, juce::File (juce::String (file)));
}

void App::importAudio (const std::string& file, int track, std::int64_t position)
{
    get().importAudio (juce::File (juce::String::fromUTF8 (file.c_str())), track, position);
}

Snap App::snap() const                { return (Snap) get().getSnap(); }
void App::setSnap (Snap newSnap)      { get().setSnap ((roughtrack::SnapGrid) newSnap); }
double App::samplesPerBeat() const    { return get().getSamplesPerBeat(); }

std::int64_t App::snapPosition (std::int64_t position, bool placeFreely) const
{
    return get().snapPosition (position, placeFreely);
}

bool App::cycleEnabled() const                  { return get().getEngine().isCycleEnabled(); }
std::int64_t App::cycleStart() const            { return get().getEngine().getCycleRange().getStart(); }
std::int64_t App::cycleEnd() const              { return get().getEngine().getCycleRange().getEnd(); }
void App::setCycleEnabled (bool value)          { get().setCycleEnabled (value); }
void App::clearCycle()                          { get().clearCycle(); }
std::int64_t App::minimumCycleLength() const    { return roughtrack::AudioEngine::minimumCycleSamples; }

void App::setCycleRange (std::int64_t start, std::int64_t end)
{
    get().setCycleRange ({ juce::jmin (start, end), juce::jmax (start, end) });
}

int App::addTrack (TrackKind kind)
{
    return get().addTrack ((roughtrack::TrackType) kind);
}

std::string App::deleteTrack (int track)
{
    return toStd (get().deleteTrack (track).getErrorMessage());
}

void App::moveTrack (int track, int newPosition)            { get().moveTrack (track, newPosition); }
void App::renameTrack (int track, const std::string& name)  { get().renameTrack (track, juce::String::fromUTF8 (name.c_str())); }

//==============================================================================
namespace
{

template <typename Parameter>
std::vector<ParameterInfo> describeParameters()
{
    std::vector<ParameterInfo> infos;

    for (int i = 0; i < (int) Parameter::count; ++i)
    {
        const auto& source = roughtrack::getParameterInfo ((Parameter) i);

        ParameterInfo info;
        info.index = i;
        info.id = source.id;
        info.label = source.label;
        info.suffix = source.suffix != nullptr ? source.suffix : "";
        info.minimum = source.minimum;
        info.maximum = source.maximum;
        info.defaultValue = source.defaultValue;
        info.isSwitch = source.isSwitch;
        infos.push_back (info);
    }

    return infos;
}

std::string formatName (const juce::PluginDescription& description)
{
    return description.pluginFormatName == "AudioUnit" ? "AU" : toStd (description.pluginFormatName);
}

} // namespace

void App::setGain (int track, float value)                 { get().setTrackGain (track, value); }
void App::setPan (int track, float value)                  { get().setTrackPan (track, value); }
void App::setInverted (int track, bool value)              { get().setTrackInverted (track, value); }
void App::setInput (int track, int first, int count)       { get().setTrackInput (track, first, count); }
int App::inputChannelCount() const                          { return get().getNumInputChannels(); }

float App::masterGain() const           { return get().getEngine().getMasterGain(); }
void App::setMasterGain (float value)   { get().setMasterGain (value); }
void App::setTempo (double value)       { get().setTempo (value); }
bool App::clickEnabled() const          { return get().getEngine().isClickEnabled(); }
void App::setClickEnabled (bool value)  { get().setClickEnabled (value); }

std::vector<ParameterInfo> App::channelParameters() const { return describeParameters<roughtrack::ChannelParameter>(); }
std::vector<ParameterInfo> App::auxParameters() const     { return describeParameters<roughtrack::AuxParameter>(); }

float App::channelParameter (int track, int index) const
{
    return juce::isPositiveAndBelow (index, (int) roughtrack::ChannelParameter::count)
               ? get().getEngine().getChannel (track).getParameter ((roughtrack::ChannelParameter) index) : 0.0f;
}

void App::setChannelParameter (int track, int index, float value)
{
    if (juce::isPositiveAndBelow (index, (int) roughtrack::ChannelParameter::count))
        get().setChannelParameter (track, (roughtrack::ChannelParameter) index, value);
}

float App::auxParameter (int index) const
{
    return juce::isPositiveAndBelow (index, (int) roughtrack::AuxParameter::count)
               ? get().getEngine().getAux().getParameter ((roughtrack::AuxParameter) index) : 0.0f;
}

void App::setAuxParameter (int index, float value)
{
    if (juce::isPositiveAndBelow (index, (int) roughtrack::AuxParameter::count))
        get().setAuxParameter ((roughtrack::AuxParameter) index, value);
}

std::string App::loadAmp (int track, const std::string& file)
{
    return toStd (get().loadAmp (track, juce::File (juce::String::fromUTF8 (file.c_str()))).getErrorMessage());
}

std::string App::loadCabinet (int track, const std::string& file)
{
    return toStd (get().loadCabinet (track, juce::File (juce::String::fromUTF8 (file.c_str()))).getErrorMessage());
}

void App::removeAmp (int track)          { get().removeAmp (track); }
void App::clearCabinet (int track)       { get().clearCabinet (track); }
std::string App::ampFolder() const       { return toStd (get().getAmpFolder().getFullPathName()); }

Tone3000Account App::tone3000Account() const
{
    Tone3000Account info;

    if (auto* tone3000 = get().getTone3000())
    {
        const auto account = tone3000->getAccount();
        info.available = account.available;
        info.signedIn = account.signedIn;
        info.signingIn = account.signingIn;
        info.browsing = account.browsing;
        info.userName = toStd (account.userName);
        info.avatarUrl = toStd (account.avatarUrl);
        info.userCode = toStd (account.userCode);
        info.verificationUrl = toStd (account.verificationUrl);
        info.error = toStd (account.error);
    }

    return info;
}

void App::tone3000SignIn()       { if (auto* t = get().getTone3000()) t->signIn(); }
void App::tone3000CancelSignIn() { if (auto* t = get().getTone3000()) t->cancelSignIn(); }
void App::tone3000SignOut()      { if (auto* t = get().getTone3000()) t->signOut(); }

void App::tone3000LoadList (const std::string& which, Tone3000Target target, int page, bool fresh)
{
    if (auto* t = get().getTone3000())
        t->loadList (fromStd (which), page, fresh, tone3000Gear (target));
}

Tone3000List App::tone3000List (const std::string& which, Tone3000Target target) const
{
    Tone3000List info;

    if (auto* t = get().getTone3000())
    {
        const auto list = t->getList (fromStd (which), tone3000Gear (target));
        info.loading = list.loading;
        info.error = toStd (list.error);
        info.page = list.page;
        info.hasMore = list.hasMore;

        for (const auto& tone : list.tones)
            info.tones.push_back (::tone3000Tone (tone));
    }

    return info;
}

void App::tone3000LoadTone (int toneId)
{
    if (auto* t = get().getTone3000())
        t->loadTone (toneId);
}

Tone3000Detail App::tone3000Tone (int toneId) const
{
    Tone3000Detail info;

    if (auto* t = get().getTone3000())
    {
        const auto detail = t->getTone (toneId);
        info.loading = detail.loading;
        info.error = toStd (detail.error);
        info.tone = ::tone3000Tone (detail.tone);

        for (const auto& model : detail.models)
        {
            Tone3000Model m;
            m.id = model.id;
            m.name = toStd (model.name);
            m.size = toStd (model.size);
            m.architecture = toStd (model.architecture);
            info.models.push_back (m);
        }
    }

    return info;
}

void App::tone3000Browse (Tone3000Target target)
{
    if (auto* t = get().getTone3000())
        t->browse (tone3000Target (target));
}

int App::tone3000TakeBrowsedTone()
{
    auto* t = get().getTone3000();
    return t != nullptr ? t->takeBrowsedTone() : 0;
}

void App::tone3000Use (int track, Tone3000Target target, int toneId, int modelId)
{
    if (auto* t = get().getTone3000())
        t->use (track, tone3000Target (target), toneId, modelId);
}

std::vector<PluginInfo> App::plugins (bool instruments) const
{
    auto& library = get().getPluginLibrary();
    const auto& list = instruments ? library.getInstruments() : library.getPlugins();
    std::vector<PluginInfo> infos;

    for (int i = 0; i < (int) list.size(); ++i)
    {
        PluginInfo info;
        info.index = i;
        info.name = toStd (list[(size_t) i].name);
        info.maker = toStd (list[(size_t) i].manufacturerName);
        info.format = formatName (list[(size_t) i]);
        infos.push_back (info);
    }

    return infos;
}

std::vector<InsertInfo> App::inserts (int track) const
{
    const auto& engine = get().getEngine();
    const auto isMidi = engine.getTrackType (track) == roughtrack::TrackType::midi;
    std::vector<InsertInfo> infos;

    for (int slot = 0; slot < roughtrack::numInsertSlots + (isMidi ? 1 : 0); ++slot)
    {
        const auto actualSlot = slot < roughtrack::numInsertSlots ? slot : roughtrack::instrumentSlot;

        InsertInfo info;
        info.slot = actualSlot;
        info.isInstrumentSlot = actualSlot == roughtrack::instrumentSlot;

        if (auto* plugin = engine.getInsert (track, actualSlot))
        {
            info.name = toStd (plugin->getName());
            info.format = formatName (plugin->getPluginDescription());
            info.bypassed = engine.isInsertBypassed (track, actualSlot);
            info.beforeAmp = engine.isInsertBeforeAmp (track, actualSlot);
        }

        infos.push_back (info);
    }

    return infos;
}

std::string App::loadPlugin (int track, int slot, int libraryIndex)
{
    return toStd (get().loadPlugin (track, slot, libraryIndex).getErrorMessage());
}

void App::removePlugin (int track, int slot)                   { get().removePlugin (track, slot); }
void App::setPluginBypassed (int track, int slot, bool value)  { get().setPluginBypassed (track, slot, value); }
void App::setPluginBeforeAmp (int track, int slot, bool value) { get().setPluginBeforeAmp (track, slot, value); }
void App::rescanPlugins()                                      { get().rescanPlugins(); }
bool App::isScanningPlugins() const                            { return get().getPluginLibrary().isScanning(); }

int App::openEditor (int track, int slot, void* parentView) { return get().openEditor (track, slot, parentView); }
bool App::isEditorOpen (int handle) const                    { return get().isEditorOpen (handle); }
void App::resizeEditor (int handle, int width, int height)  { get().resizeEditor (handle, width, height); }
void App::closeEditor (int handle)                           { get().closeEditor (handle); }

EditorSize App::editorSize (int handle) const
{
    const auto size = get().getEditorSize (handle);
    return { size.getWidth(), size.getHeight(), get().isEditorResizable (handle) };
}

//==============================================================================
void App::play()             { get().play(); }
void App::stop()             { get().stop(); }
void App::returnToStart()    { get().returnToStart(); }
void App::seek (std::int64_t position) { get().seek (position); }

std::string App::record()
{
    return get().record().getErrorMessage().toStdString();
}

Transport App::transport() const
{
    switch (get().getEngine().getState())
    {
        case roughtrack::TransportState::playing:   return Transport::playing;
        case roughtrack::TransportState::recording: return Transport::recording;
        case roughtrack::TransportState::stopped:   break;
    }

    return Transport::stopped;
}

std::int64_t App::position() const      { return get().getDisplayPosition(); }
double App::sampleRate() const          { return timelineRate(); }
double App::tempo() const               { return get().getEngine().getTempo(); }
std::int64_t App::sessionLength() const { return get().getEngine().getSessionLength(); }

//==============================================================================
void App::setMuted (int track, bool value)      { get().setTrackMuted (track, value); }
void App::setSoloed (int track, bool value)     { get().setTrackSoloed (track, value); }
void App::setArmed (int track, bool value)      { get().setTrackArmed (track, value); }
void App::setMonitoring (int track, bool value) { get().setTrackMonitoring (track, value); }

float App::trackLevel (int track) const { return get().getEngine().getTrackLevel (track); }
float App::masterLevel() const          { return get().getEngine().getMasterLevel(); }

//==============================================================================
bool App::canUndo() const          { return get().canUndo(); }
bool App::canRedo() const          { return get().canRedo(); }
std::string App::undoName() const  { return get().getUndoName().toStdString(); }
std::string App::redoName() const  { return get().getRedoName().toStdString(); }
void App::undo()                   { get().undo(); }
void App::redo()                   { get().redo(); }

//==============================================================================
bool App::isRestoringPlugins() const { return get().isRestoringPlugins(); }

std::vector<Message> App::takeMessages()
{
    std::vector<Message> taken;

    for (const auto& message : get().takeMessages())
        taken.push_back ({ message.text.toStdString(), message.isWarning });

    return taken;
}

//==============================================================================
AudioDeviceInfo App::audioDevice() const
{
    auto& manager = get().getDeviceManager();
    AudioDeviceInfo info;

    if (auto* type = manager.getCurrentDeviceTypeObject())
        for (const auto& name : type->getDeviceNames (false))
            info.devices.push_back (name.toStdString());

    if (auto* device = manager.getCurrentAudioDevice())
    {
        info.name = device->getName().toStdString();
        info.sampleRate = device->getCurrentSampleRate();
        info.bufferSize = device->getCurrentBufferSizeSamples();

        for (const auto rate : device->getAvailableSampleRates())
            info.sampleRates.push_back (rate);

        for (const auto size : device->getAvailableBufferSizes())
            info.bufferSizes.push_back (size);
    }

    return info;
}

std::string App::chooseAudioDevice (const std::string& name, double rate, int bufferSize)
{
    return get().chooseAudioDevice (name, rate, bufferSize).toStdString();
}

//==============================================================================
void startStudio()
{
    if (studio != nullptr)
        return;

    juceInitialiser = std::make_unique<juce::ScopedJuceInitialiser_GUI>();
    studio = std::make_unique<roughtrack::Studio> (roughtrack::StudioPaths::forApp());
    studio->start();
}

void stopStudio()
{
    studio.reset();
    juceInitialiser.reset();
}

App* app()
{
    return studio != nullptr ? &theApp : nullptr;
}

bool isPluginScanChild (const char* firstArgument)
{
    return firstArgument != nullptr && juce::String (firstArgument) == roughtrack::scanChildArgument;
}

int runPluginScanChild (const char* format, const char* identifier, const char* resultFile)
{
    const juce::ScopedJuceInitialiser_GUI initialiser;
    juce::AudioPluginFormatManager formats;
    roughtrack::addPluginFormats (formats);

    const auto found = roughtrack::writePluginScanResult (formats,
                                                          { juce::String (format), juce::String (identifier) },
                                                          juce::File (juce::String (resultFile)));
    return found ? 0 : 1;
}

} // namespace rt

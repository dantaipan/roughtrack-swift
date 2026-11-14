#pragma once

#include "roughtrack/AmpModel.h"

#include <juce_dsp/juce_dsp.h>

#include <array>
#include <atomic>
#include <memory>

namespace roughtrack
{

enum class ChannelParameter
{
    ampEnabled,
    ampInput,
    eqEnabled,
    highPass,
    lowGain,
    midGain,
    midFrequency,
    highGain,
    compressorEnabled,
    compressorThreshold,
    compressorRatio,
    compressorMakeup,
    sendReverb,
    sendDelay,
    count
};

struct ParameterInfo
{
    const char* id;
    const char* label;
    float minimum, maximum, defaultValue;
    const char* suffix;
    bool isSwitch = false;
};

const ParameterInfo& getParameterInfo (ChannelParameter);

/** Where an amp capture or cabinet IR came from when it was downloaded rather
    than picked from disk: enough to show it and to download it again. The engine
    only keeps and saves it; the core knows what it means.
*/
struct FileSource
{
    int toneId = 0, modelId = 0;
    juce::String title, model, creator, url;

    bool isValid() const noexcept { return toneId > 0 && modelId > 0; }
    bool operator== (const FileSource&) const = default;
};

/** The built-in processing on one track. Each plugin insert runs either before
    the amp, like a pedal, or between the amp and the EQ and compressor.
    Nothing here adds latency, so none of it affects delay compensation.

    Parameters can change from any thread at any time. prepare() and the amp and
    cabinet calls belong to the message thread.
*/
class ChannelStrip
{
public:
    ChannelStrip();

    void prepare (double sampleRate, int maximumBlockSize);

    void setParameter (ChannelParameter, float value) noexcept;
    float getParameter (ChannelParameter) const noexcept;
    void resetParameters() noexcept;

    /** Returns what was there, to delete outside any lock. */
    std::unique_ptr<AmpModel> exchangeAmp (std::unique_ptr<AmpModel>);
    bool hasAmp() const noexcept { return amp != nullptr; }

    juce::File getAmpFile() const { return ampFile; }
    void setAmpFile (const juce::File& file) { ampFile = file; }

    juce::Result loadCabinet (const juce::File&);
    void clearCabinet();
    juce::File getCabinetFile() const { return cabinetFile; }

    /** A cabinet that couldn't load, such as a file that has gone: silent, but
        remembered so saving keeps it and it can load later. */
    void setMissingCabinet (const juce::File&);

    /** Where the capture and IR came from. Message thread only. */
    const FileSource& getAmpSource() const noexcept { return ampSource; }
    void setAmpSource (const FileSource& source) { ampSource = source; }
    const FileSource& getCabinetSource() const noexcept { return cabinetSource; }
    void setCabinetSource (const FileSource& source) { cabinetSource = source; }

    void processAmp (float* left, float* right, int numSamples) noexcept;
    void processChannel (float* left, float* right, int numSamples) noexcept;

private:
    struct Biquad
    {
        void setCoefficients (const std::array<float, 6>&) noexcept;
        void process (float* samples, int numSamples, int channel) noexcept;
        void reset() noexcept;

        float b0 = 1.0f, b1 = 0.0f, b2 = 0.0f, a1 = 0.0f, a2 = 0.0f;
        std::array<std::array<float, 2>, 2> state {};
    };

    void updateFilters() noexcept;

    std::array<std::atomic<float>, (size_t) ChannelParameter::count> parameters;

    std::unique_ptr<AmpModel> amp;
    juce::File ampFile, cabinetFile;
    FileSource ampSource, cabinetSource;

    std::atomic<bool> cabinetLoaded { false };
    juce::dsp::Convolution cabinet;

    juce::dsp::Compressor<float> compressor;
    Biquad highPassFilter, lowShelf, midPeak, highShelf;

    std::array<float, 5> filterValues {};
    bool filtersValid = false;

    double currentSampleRate = 48000.0;
    int maximumSamples = 0;
};

enum class AuxParameter
{
    reverbSize,
    reverbDamping,
    reverbReturn,
    delayTime,
    delaySync,
    delayFeedback,
    delayReturn,
    count
};

const ParameterInfo& getParameterInfo (AuxParameter);

/** A shared reverb and delay that tracks send to, so seven tracks can use one
    instance of each.
*/
class AuxBuses
{
public:
    AuxBuses();

    void prepare (double sampleRate, int maximumBlockSize);
    void setParameter (AuxParameter, float value) noexcept;
    float getParameter (AuxParameter) const noexcept;
    void resetParameters() noexcept;

    void clearSends (int numSamples) noexcept;
    void addToSends (const float* left, const float* right, float reverbLevel, float delayLevel, int numSamples) noexcept;

    /** Runs the effects and adds their output to the mix. */
    void addReturns (float* left, float* right, int numSamples, double tempo) noexcept;

private:
    std::array<std::atomic<float>, (size_t) AuxParameter::count> parameters;

    juce::AudioBuffer<float> reverbSend, delaySend, delayLine;
    juce::Reverb reverb;
    int delayWritePosition = 0;
    double currentSampleRate = 48000.0;
};

} // namespace roughtrack

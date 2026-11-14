#include "TestHelpers.h"

#include "roughtrack/Session.h"
#include "roughtrack/Tone3000.h"

#include <catch2/catch_test_macros.hpp>

using namespace roughtrack;

namespace
{

constexpr double sampleRate = 48000.0;

FileSource makeSource (int toneId, int modelId, const juce::String& title)
{
    FileSource source;
    source.toneId = toneId;
    source.modelId = modelId;
    source.title = title;
    source.model = title + " model";
    source.creator = "someone";
    source.url = "https://www.tone3000.com/tones/" + juce::String (toneId);
    return source;
}

/** A short impulse, which is all a cabinet needs to load. */
juce::File writeImpulse (const juce::File& file)
{
    juce::AudioBuffer<float> impulse (1, 64);
    impulse.clear();
    impulse.setSample (0, 0, 1.0f);
    test::writeWav (file, impulse, sampleRate);
    return file;
}

std::unique_ptr<AudioEngine> restore (const AudioEngine& engine, const juce::File& directory)
{
    const auto xml = createSessionXml (engine, directory);
    auto restored = std::make_unique<AudioEngine>();
    restored->prepare (sampleRate, 64);
    applySessionXml (*restored, *xml, directory);
    return restored;
}

} // namespace

TEST_CASE ("A session keeps where its capture and IR came from on TONE3000")
{
    test::TempDirectory temp;
    AudioEngine engine;
    test::useTracks (engine);
    engine.setSessionDirectory (temp.directory);
    engine.prepare (sampleRate, 64);

    // A capture that isn't here is still remembered, which is all this needs.
    const auto capture = temp.directory.getChildFile ("Downloads/12/34 - Plexi.nam");
    engine.restoreAmp (1, capture);
    engine.getChannel (1).setAmpSource (makeSource (12, 34, "Plexi"));

    const auto impulse = writeImpulse (temp.directory.getChildFile ("cab.wav"));
    REQUIRE (engine.getChannel (1).loadCabinet (impulse).wasOk());
    engine.getChannel (1).setCabinetSource (makeSource (56, 78, "4x12"));

    // A file picked from disk has no source, and gets none back.
    REQUIRE (engine.getChannel (2).loadCabinet (impulse).wasOk());

    const auto restored = restore (engine, temp.directory);

    CHECK (restored->getChannel (1).getAmpFile() == capture);
    CHECK (restored->getChannel (1).getAmpSource() == makeSource (12, 34, "Plexi"));
    CHECK (restored->getChannel (1).getCabinetSource() == makeSource (56, 78, "4x12"));
    CHECK (! restored->getChannel (2).getCabinetSource().isValid());
}

TEST_CASE ("A missing cabinet IR is kept, so saving again doesn't lose it")
{
    test::TempDirectory temp;
    AudioEngine engine;
    test::useTracks (engine);
    engine.prepare (sampleRate, 64);

    const auto impulse = writeImpulse (temp.directory.getChildFile ("cab.wav"));
    REQUIRE (engine.getChannel (0).loadCabinet (impulse).wasOk());
    engine.getChannel (0).setCabinetSource (makeSource (5, 6, "Cab"));

    const auto xml = createSessionXml (engine, temp.directory);
    impulse.deleteFile();

    AudioEngine restored;
    restored.prepare (sampleRate, 64);

    const auto result = applySessionXml (restored, *xml, temp.directory);

    CHECK (result.failed());
    CHECK (result.getErrorMessage().contains ("cab.wav"));
    CHECK (restored.getChannel (0).getCabinetFile() == impulse);
    CHECK (restored.getChannel (0).getCabinetSource() == makeSource (5, 6, "Cab"));

    const auto again = restore (restored, temp.directory);
    CHECK (again->getChannel (0).getCabinetFile() == impulse);
}

TEST_CASE ("Removing a capture or clearing a cabinet forgets where it came from")
{
    test::TempDirectory temp;
    AudioEngine engine;
    test::useTracks (engine);
    engine.prepare (sampleRate, 64);

    engine.restoreAmp (0, temp.directory.getChildFile ("gone.nam"));
    engine.getChannel (0).setAmpSource (makeSource (1, 2, "Amp"));
    engine.removeAmp (0);
    CHECK (! engine.getChannel (0).getAmpSource().isValid());

    REQUIRE (engine.getChannel (0).loadCabinet (writeImpulse (temp.directory.getChildFile ("cab.wav"))).wasOk());
    engine.getChannel (0).setCabinetSource (makeSource (3, 4, "Cab"));
    engine.getChannel (0).clearCabinet();
    CHECK (! engine.getChannel (0).getCabinetSource().isValid());
}

TEST_CASE ("A TONE3000 download's path gives back its tone and model")
{
    const juce::File downloads ("/tmp/TONE3000 Shared/Downloads");

    const auto source = sourceFromDownloadPath (downloads.getChildFile ("4321/987 - Clean - Room.nam"), downloads);
    CHECK (source.toneId == 4321);
    CHECK (source.modelId == 987);
    CHECK (source.model == "Clean - Room");

    // Anything else isn't one
    CHECK (! sourceFromDownloadPath (juce::File ("/tmp/elsewhere/4321/987 - Amp.nam"), downloads).isValid());
    CHECK (! sourceFromDownloadPath (downloads.getChildFile ("987 - Amp.nam"), downloads).isValid());
    CHECK (! sourceFromDownloadPath (downloads.getChildFile ("4321/extra/987 - Amp.nam"), downloads).isValid());
    CHECK (! sourceFromDownloadPath (downloads.getChildFile ("tones/987 - Amp.nam"), downloads).isValid());
    CHECK (! sourceFromDownloadPath (downloads.getChildFile ("4321/Amp.nam"), downloads).isValid());
    CHECK (! sourceFromDownloadPath (juce::File(), downloads).isValid());
}

TEST_CASE ("A missing file from TONE3000 is downloaded again only when it can be")
{
    const auto source = makeSource (1, 2, "Amp");

    CHECK (redownloadFor (source, false, true, true) == Redownload::download);
    CHECK (redownloadFor (source, false, true, false) == Redownload::needsSignIn);
    CHECK (redownloadFor (source, false, false, false) == Redownload::unavailable);

    // Nothing to do when the file is there, or it never came from TONE3000
    CHECK (redownloadFor (source, true, true, true) == Redownload::none);
    CHECK (redownloadFor ({}, false, true, true) == Redownload::none);
}

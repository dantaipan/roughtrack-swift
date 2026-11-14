#include "roughtrack/Tone3000.h"

#include <rs_t3k/Config.h>

namespace roughtrack
{

FileSource sourceFromDownloadPath (const juce::File& file, const juce::File& downloadsFolder)
{
    // <downloads>/<toneId>/<modelId> - <name>.<ext>
    if (file == juce::File() || ! file.isAChildOf (downloadsFolder) || file.getParentDirectory().getParentDirectory() != downloadsFolder)
        return {};

    const auto name = file.getFileNameWithoutExtension();
    const auto toneText = file.getParentDirectory().getFileName();
    const auto modelText = name.upToFirstOccurrenceOf (" - ", false, false);

    if (! toneText.containsOnly ("0123456789") || ! modelText.containsOnly ("0123456789")
        || toneText.isEmpty() || modelText.isEmpty() || ! name.contains (" - "))
        return {};

    FileSource source;
    source.toneId = toneText.getIntValue();
    source.modelId = modelText.getIntValue();
    source.model = name.fromFirstOccurrenceOf (" - ", false, false);
    source.title = source.model;
    return source;
}

Redownload redownloadFor (const FileSource& source, bool fileExists, bool available, bool signedIn)
{
    if (! source.isValid() || fileExists)
        return Redownload::none;

    if (! available)
        return Redownload::unavailable;

    return signedIn ? Redownload::download : Redownload::needsSignIn;
}

namespace
{
FileSource sourceFor (const rs::t3k::Tone& tone, const rs::t3k::Model& model)
{
    FileSource source;
    source.toneId = tone.id;
    source.modelId = model.id;
    source.title = tone.title;
    source.model = model.name;
    source.creator = tone.creator.name();
    source.url = tone.url;
    return source;
}

/** Enough of a tone to find or name its download, from what a session kept. */
rs::t3k::Tone toneFor (const FileSource& source)
{
    rs::t3k::Tone tone;
    tone.id = source.toneId;
    tone.title = source.title;
    tone.url = source.url;
    tone.creator.displayName = source.creator;
    return tone;
}
} // namespace

//==============================================================================
Tone3000::Tone3000 (Tone3000Hooks h)
    : hooks (std::move (h)),
      service (std::make_unique<rs::t3k::Service>())
{
    account.available = service->isAvailable();
    account.signedIn = account.available && service->isSignedIn();

    if (account.signedIn)
        fetchUser();
}

Tone3000::~Tone3000() = default;

juce::String Tone3000::targetName (Tone3000Target target)
{
    return target == Tone3000Target::amp ? "capture" : "cabinet IR";
}

Tone3000::Account Tone3000::getAccount() const
{
    auto copy = account;
    // Another app sharing the sign-in may have signed in or out since.
    copy.signedIn = account.available && service->isSignedIn();
    copy.browsing = service->isBrowsing();
    return copy;
}

void Tone3000::signIn()
{
    if (! account.available || account.signingIn)
        return;

    account.signingIn = true;
    account.userCode.clear();
    account.verificationUrl.clear();
    account.error.clear();
    hooks.changed();

    juce::WeakReference<Tone3000> self (this);

    service->startSignIn (
        [self] (const rs::t3k::Api::DeviceCode& code)
        {
            if (auto* t = self.get())
            {
                t->account.userCode = code.userCode;
                t->account.verificationUrl = code.verificationUriComplete.isNotEmpty() ? code.verificationUriComplete
                                                                                       : code.verificationUri;
                t->hooks.changed();
            }
        },
        [self] (bool ok, const juce::String& error)
        {
            if (auto* t = self.get())
            {
                t->account.signingIn = false;
                t->account.userCode.clear();
                t->account.verificationUrl.clear();
                t->account.error = ok ? juce::String() : error;

                if (ok)
                    t->signedIn();

                t->hooks.changed();
            }
        });
}

void Tone3000::cancelSignIn()
{
    service->cancelSignIn();
    account.signingIn = false;
    account.userCode.clear();
    account.verificationUrl.clear();
    hooks.changed();
}

void Tone3000::signOut()
{
    service->signOut();
    account.signedIn = false;
    account.userName.clear();
    account.avatarUrl.clear();
    account.error.clear();
    lists.clear();
    details.clear();
    hooks.changed();
}

void Tone3000::signedIn()
{
    account.signedIn = true;
    lists.clear();
    fetchUser();
    checkTracks();
}

void Tone3000::fetchUser()
{
    juce::WeakReference<Tone3000> self (this);

    service->user ([self] (bool ok, const rs::t3k::User& user, const juce::String&)
    {
        if (auto* t = self.get(); t != nullptr && ok)
        {
            t->account.userName = user.name();
            t->account.avatarUrl = user.avatarUrl;
            t->hooks.changed();
        }
    });
}

//==============================================================================
void Tone3000::loadList (const juce::String& which, int page, bool fresh, const juce::String& gear)
{
    const auto key = which + "|" + gear;
    auto& list = lists[key];

    if (list.loading)
        return;

    list.loading = true;
    list.error.clear();
    hooks.changed();

    juce::WeakReference<Tone3000> self (this);

    service->tones (which, juce::jmax (1, page), [self, key, page] (bool ok, const rs::t3k::Page<rs::t3k::Tone>& got, const juce::String& error)
    {
        auto* t = self.get();

        if (t == nullptr)
            return;

        auto& l = t->lists[key];
        l.loading = false;

        if (! ok)
        {
            l.error = error;
        }
        else
        {
            if (page <= 1)
                l.tones.clear();

            l.tones.insert (l.tones.end(), got.items.begin(), got.items.end());
            l.page = got.page;
            l.hasMore = got.hasMore();
        }

        t->hooks.changed();
    }, fresh, gear);
}

Tone3000::List Tone3000::getList (const juce::String& which, const juce::String& gear) const
{
    const auto it = lists.find (which + "|" + gear);
    return it == lists.end() ? List() : it->second;
}

void Tone3000::loadTone (int toneId)
{
    auto& detail = details[toneId];

    if (detail.loading)
        return;

    detail.loading = true;
    detail.error.clear();
    hooks.changed();

    juce::WeakReference<Tone3000> self (this);

    service->tone (toneId, [self, toneId] (bool ok, const rs::t3k::Tone& tone, const juce::String& error)
    {
        auto* t = self.get();

        if (t == nullptr)
            return;

        if (! ok)
        {
            auto& d = t->details[toneId];
            d.loading = false;
            d.error = rs::t3k::Service::isUnavailable (t->service->lastStatus()) ? juce::String ("This tone is private or no longer on TONE3000.")
                                                                                  : error;
            t->hooks.changed();
            return;
        }

        t->details[toneId].tone = tone;

        t->service->models (toneId, [self, toneId] (bool modelsOk, const std::vector<rs::t3k::Model>& models, const juce::String& modelsError)
        {
            if (auto* u = self.get())
            {
                auto& d = u->details[toneId];
                d.loading = false;
                d.models = models;
                d.error = modelsOk ? juce::String() : modelsError;
                u->hooks.changed();
            }
        });
    });
}

Tone3000::Detail Tone3000::getTone (int toneId) const
{
    const auto it = details.find (toneId);
    return it == details.end() ? Detail() : it->second;
}

void Tone3000::browse (Tone3000Target target)
{
    juce::WeakReference<Tone3000> self (this);

    service->browse (target == Tone3000Target::amp ? "nam" : "ir", 0, [self] (int toneId, const juce::String& error)
    {
        if (auto* t = self.get())
        {
            t->browsedTone = toneId;
            t->account.signedIn = t->service->isSignedIn();

            if (error.isNotEmpty())
                t->hooks.message ("TONE3000: " + error.upToFirstOccurrenceOf (" Try the RoughStomp app.", false, false), true);

            t->hooks.changed();
        }
    });

    hooks.changed();
}

int Tone3000::takeBrowsedTone()
{
    return std::exchange (browsedTone, 0);
}

//==============================================================================
void Tone3000::use (int track, Tone3000Target target, int toneId, int modelId)
{
    const auto detail = getTone (toneId);
    const auto model = std::find_if (detail.models.begin(), detail.models.end(), [modelId] (const auto& m) { return m.id == modelId; });

    if (model == detail.models.end())
        return;

    const auto source = sourceFor (detail.tone, *model);
    setLoading (track, target, true);

    juce::WeakReference<Tone3000> self (this);

    service->download (detail.tone, *model, [self, track, target, source] (const juce::File& file, const juce::String& error)
    {
        auto* t = self.get();

        if (t == nullptr)
            return;

        t->setLoading (track, target, false);

        if (! file.existsAsFile())
        {
            t->hooks.message ("Couldn't download " + source.title + " from TONE3000: " + error, true);
            return;
        }

        if (const auto result = t->hooks.load (track, target, file, source); result.failed())
            t->hooks.message ("Couldn't load " + source.title + ": " + result.getErrorMessage(), true);
    });
}

bool Tone3000::isLoading (int track, Tone3000Target target) const
{
    return loading.count ({ track, target }) > 0;
}

void Tone3000::setLoading (int track, Tone3000Target target, bool isNowLoading)
{
    if (isNowLoading)
        loading.insert ({ track, target });
    else
        loading.erase ({ track, target });

    hooks.changed();
}

//==============================================================================
void Tone3000::checkTracks()
{
    const auto downloads = rs::t3k::config::downloadsFolder();
    const bool signedInNow = account.available && service->isSignedIn();

    for (const auto track : hooks.tracks())
    {
        for (const auto target : { Tone3000Target::amp, Tone3000Target::cabinet })
        {
            const auto file = hooks.fileOf (track, target);

            if (file == juce::File())
                continue;

            auto source = hooks.sourceOf (track, target);

            if (! source.isValid())
            {
                source = sourceFromDownloadPath (file, downloads);

                if (source.isValid())
                    hooks.setSource (track, target, source);
            }

            switch (redownloadFor (source, file.existsAsFile(), account.available, signedInNow))
            {
                case Redownload::none:
                    break;
                case Redownload::download:
                    if (! isLoading (track, target))
                        redownload (track, target, source, file);
                    break;
                case Redownload::needsSignIn:
                    hooks.message ("Sign in to TONE3000 to download " + source.title + " again.", true);
                    break;
                case Redownload::unavailable:
                    hooks.message (source.title + " came from TONE3000, which this build can't reach.", true);
                    break;
            }
        }
    }
}

void Tone3000::redownload (int track, Tone3000Target target, const FileSource& source, const juce::File& file)
{
    setLoading (track, target, true);
    hooks.message ("Downloading " + source.title + " from TONE3000...", false);

    juce::WeakReference<Tone3000> self (this);

    // Still waiting for this? (Something else may have been loaded since.)
    auto stillWanted = [self, track, target, source, file]
    {
        auto* t = self.get();
        return t != nullptr && t->hooks.fileOf (track, target) == file && t->hooks.sourceOf (track, target).modelId == source.modelId;
    };

    service->model (source.modelId, [self, track, target, source, stillWanted] (bool ok, const rs::t3k::Model& model, const juce::String& error)
    {
        auto* t = self.get();

        if (t == nullptr)
            return;

        if (! stillWanted())
            return t->setLoading (track, target, false);

        if (! ok)
        {
            t->setLoading (track, target, false);
            t->hooks.message (rs::t3k::Service::isUnavailable (t->service->lastStatus())
                                  ? source.title + " is no longer available on TONE3000."
                                  : "Couldn't download " + source.title + " again: " + error,
                              true);
            return;
        }

        t->service->download (toneFor (source), model, [self, track, target, source, stillWanted] (const juce::File& got, const juce::String& e)
        {
            auto* u = self.get();

            if (u == nullptr)
                return;

            u->setLoading (track, target, false);

            if (! stillWanted())
                return;

            if (! got.existsAsFile())
            {
                u->hooks.message ("Couldn't download " + source.title + " again: " + e, true);
                return;
            }

            if (const auto result = u->hooks.load (track, target, got, source); result.failed())
                u->hooks.message ("Couldn't load " + source.title + ": " + result.getErrorMessage(), true);
            else
                u->hooks.message ("Downloaded " + source.title + " again.", false);
        });
    });
}

} // namespace roughtrack

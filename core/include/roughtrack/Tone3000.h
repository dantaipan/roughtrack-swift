#pragma once

#include "roughtrack/ChannelStrip.h"

#include <juce_events/juce_events.h>
#include <rs_t3k/Service.h>

#include <functional>
#include <map>
#include <memory>
#include <set>
#include <vector>

namespace roughtrack
{

/** Which of a track's built-in files: the amp capture or the cabinet IR. */
enum class Tone3000Target { amp, cabinet };

/** What the studio does for TONE3000: loading a downloaded file into a track, and
    reading a track's files back. Kept to these, so Tone3000 can be tested alone.
*/
struct Tone3000Hooks
{
    std::function<void()> changed;
    std::function<void (const juce::String&, bool isWarning)> message;
    std::function<std::vector<int>()> tracks;
    std::function<juce::File (int track, Tone3000Target)> fileOf;
    std::function<FileSource (int track, Tone3000Target)> sourceOf;
    std::function<void (int track, Tone3000Target, const FileSource&)> setSource;
    std::function<juce::Result (int track, Tone3000Target, const juce::File&, const FileSource&)> load;
};

/** A file under the shared Downloads folder is named <toneId>/<modelId> - <name>,
    which gives its tone and model back when a session lost them (the JUCE
    RoughTrack drops what it doesn't know when it saves). Empty for any other file.
*/
FileSource sourceFromDownloadPath (const juce::File& file, const juce::File& downloadsFolder);

/** What to do about a track's file from TONE3000 that's missing. */
enum class Redownload { none, download, needsSignIn, unavailable };
Redownload redownloadFor (const FileSource&, bool fileExists, bool available, bool signedIn);

/** TONE3000 (tone3000.com) for the studio: the shared sign-in, the tone lists, a
    tone's models, and downloading a model into a track's amp or cab. Built on
    RoughStomp's rs::t3k::Service, whose replies come back on the message thread.
    Each reply updates what's kept here and calls hooks.changed, so the UI reads it
    again on its next poll. Everything here belongs to the message thread.
*/
class Tone3000 final
{
public:
    explicit Tone3000 (Tone3000Hooks);
    ~Tone3000();

    struct Account
    {
        bool available = false, signedIn = false, signingIn = false, browsing = false;
        juce::String userName, avatarUrl;
        juce::String userCode, verificationUrl;   // while signing in
        juce::String error;
    };

    struct List
    {
        bool loading = false;
        juce::String error;
        std::vector<rs::t3k::Tone> tones;
        int page = 0;
        bool hasMore = false;
    };

    struct Detail
    {
        bool loading = false;
        juce::String error;
        rs::t3k::Tone tone;
        std::vector<rs::t3k::Model> models;
    };

    Account getAccount() const;
    void signIn();
    void cancelSignIn();
    void signOut();

    /** which: favorited, created, downloaded, trending or latest. Page 1 starts the
        list again; later pages add to it. gear narrows it ("cab" for cabinet IRs,
        since the lists mix every format); latest ignores it. */
    void loadList (const juce::String& which, int page, bool fresh, const juce::String& gear = {});
    List getList (const juce::String& which, const juce::String& gear = {}) const;

    void loadTone (int toneId);
    Detail getTone (int toneId) const;

    /** TONE3000's own picker in the browser; the chosen tone comes back through
        takeBrowsedTone (0 until then). */
    void browse (Tone3000Target);
    int takeBrowsedTone();

    /** Downloads the model (unless it's already here) and loads it into the track. */
    void use (int track, Tone3000Target, int toneId, int modelId);
    bool isLoading (int track, Tone3000Target) const;

    /** After a session opens, and after signing in: fills in sources from download
        paths, and downloads again any file from TONE3000 that has gone. */
    void checkTracks();

private:
    void signedIn();
    void fetchUser();
    void redownload (int track, Tone3000Target, const FileSource&, const juce::File&);
    void setLoading (int track, Tone3000Target, bool);
    static juce::String targetName (Tone3000Target);

    Tone3000Hooks hooks;
    std::unique_ptr<rs::t3k::Service> service;

    Account account;
    std::map<juce::String, List> lists;
    std::map<int, Detail> details;
    std::set<std::pair<int, Tone3000Target>> loading;
    int browsedTone = 0;

    JUCE_DECLARE_WEAK_REFERENCEABLE (Tone3000)
};

} // namespace roughtrack

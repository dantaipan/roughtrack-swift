#pragma once

#include <juce_audio_processors/juce_audio_processors.h>

namespace roughtrack
{

/** A plugin's own editor, attached to a view another toolkit made (a SwiftUI window's,
    here), as a host's plugin window does. It must go before the plugin does.
*/
class HostedEditor
{
public:
    HostedEditor (juce::AudioPluginInstance&, void* parentView, int track, int slot);
    ~HostedEditor();

    /** The editor's size on screen, counting the scale a VST3 is given. */
    juce::Rectangle<int> getSize() const;

    /** Follows the window being resized, if the editor can be. */
    void setSize (int width, int height);

    bool isResizable() const;

    const int track, slot;

private:
    std::unique_ptr<juce::AudioProcessorEditor> editor;
};

} // namespace roughtrack

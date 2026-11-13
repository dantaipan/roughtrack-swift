#include "roughtrack/HostedEditor.h"

namespace roughtrack
{

namespace
{

juce::AudioProcessorEditor* createEditor (juce::AudioPluginInstance& plugin)
{
    if (auto* editor = plugin.createEditorAndMakeActive())
        return editor;

    return new juce::GenericAudioProcessorEditor (plugin);
}

/** JUCE tells a VST3 editor the content scale is 1 even on a Retina display, and plugins
    that believe it draw at half size in one corner. Setting the real scale corrects them.
    From RoughTrack's PluginWindow.
*/
void applyDisplayScale (juce::AudioPluginInstance& plugin, juce::AudioProcessorEditor& editor)
{
    if (plugin.getPluginDescription().pluginFormatName != "VST3")
        return;

    if (const auto* display = juce::Desktop::getInstance().getDisplays().getPrimaryDisplay())
        editor.setScaleFactor ((float) display->scale);
}

float transformScale (const juce::Component& component)
{
    // The horizontal scale; editors are only ever scaled evenly, never rotated.
    const auto transform = component.getTransform();
    return std::hypot (transform.mat00, transform.mat10);
}

} // namespace

HostedEditor::HostedEditor (juce::AudioPluginInstance& plugin, void* parentView, int trackToUse, int slotToUse)
    : track (trackToUse),
      slot (slotToUse),
      editor (createEditor (plugin))
{
    applyDisplayScale (plugin, *editor);
    editor->setTopLeftPosition (0, 0);
    editor->addToDesktop (0, parentView);
    editor->setVisible (true);
}

HostedEditor::~HostedEditor()
{
    editor.reset();
}

juce::Rectangle<int> HostedEditor::getSize() const
{
    return editor->getLocalBounds().transformedBy (editor->getTransform()).withZeroOrigin();
}

bool HostedEditor::isResizable() const
{
    return editor->isResizable();
}

void HostedEditor::setSize (int width, int height)
{
    if (! editor->isResizable() || (getSize().getWidth() == width && getSize().getHeight() == height))
        return;

    const auto scale = transformScale (*editor);
    editor->setSize (juce::roundToInt ((float) width / scale), juce::roundToInt ((float) height / scale));
}

} // namespace roughtrack

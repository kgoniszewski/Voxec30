#pragma once

#include <juce_audio_processors/juce_audio_processors.h>

#include "PluginProcessor.h"
#include "gui/VoxLookAndFeel.h"

//==============================================================================
/** Touch-first, fully vector, landscape UI for iPad Pro.

    Layout (proportional, recomputed in resized() - works from 11" to 13"
    and in Stage Manager / Split View windows):

      +--------------------------------------------------------------+
      | header: model name / circuit info                            |
      +--------------------------------------------------------------+
      |  copper control panel:  VOLUME TREBLE BASS  CUT  MASTER  (o) |
      +--------------------------------------------------------------+
      |  diamond grille cloth + badge                                |
      +--------------------------------------------------------------+
      | IN/OUT meters | INPUT | AUDIO I/O | CAB | LOAD IR | DEFAULT   |
      +--------------------------------------------------------------+
*/
class VoxAC30Editor final : public juce::AudioProcessorEditor,
                            private juce::Timer,
                            private juce::Value::Listener
{
public:
    explicit VoxAC30Editor (VoxAC30Processor&);
    ~VoxAC30Editor() override;

    void paint (juce::Graphics&) override;
    void resized() override;

private:
    //==============================================================================
    struct AmpKnob final : public juce::Component
    {
        AmpKnob (juce::AudioProcessorValueTreeState& state, const juce::String& paramId,
                 const juce::String& title, const juce::String& hint = {});

        void resized() override;

        juce::Slider slider;
        juce::Label  name, subtitle;
        juce::AudioProcessorValueTreeState::SliderAttachment attachment;
    };

    struct LevelMeter final : public juce::Component
    {
        explicit LevelMeter (juce::String label) : text (std::move (label)) {}
        void push (float peak) noexcept;
        void paint (juce::Graphics&) override;

        juce::String text;
        float level = 0.0f, hold = 0.0f;
        int holdFrames = 0;
    };

    //==============================================================================
    void timerCallback() override;
    void valueChanged (juce::Value&) override;

    void chooseImpulseResponse();
    void importImpulseResponse (const juce::URL& url);
    void updateInputButton();
    void updateCabinetLabel();

    void renderBackground();
    void paintPanel (juce::Graphics&, juce::Rectangle<float>) const;
    void paintGrille (juce::Graphics&, juce::Rectangle<float>) const;

    //==============================================================================
    VoxAC30Processor& processor;
    vox::gui::VoxLookAndFeel lookAndFeel;

    AmpKnob volumeKnob, trebleKnob, bassKnob, cutKnob, masterKnob;

    LevelMeter inputMeter { "IN" }, outputMeter { "OUT" };

    juce::TextButton inputButton, audioButton { "AUDIO I/O" }, cabButton { "CAB" },
                     loadIrButton { "LOAD IR" }, defaultIrButton { "DEFAULT IR" };
    juce::Label irLabel;

    juce::AudioProcessorValueTreeState::ButtonAttachment cabAttachment;

    juce::Value inputMuted;
    std::unique_ptr<juce::FileChooser> fileChooser;

    juce::Image backgroundCache;
    juce::Rectangle<float> headerArea, panelArea, grilleArea, toolbarArea;
    float pilotPhase = 0.0f;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (VoxAC30Editor)
};

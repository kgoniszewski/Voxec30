#pragma once

#include <juce_gui_basics/juce_gui_basics.h>

namespace vox::gui
{
    namespace Palette
    {
        inline const juce::Colour tolex       { 0xff141210 };
        inline const juce::Colour copperLight { 0xffd9a46a };
        inline const juce::Colour copperDark  { 0xff8a5a2b };
        inline const juce::Colour panelInk    { 0xff2a1a0e };
        inline const juce::Colour cream       { 0xfff2e6c9 };
        inline const juce::Colour grilleA     { 0xff3d2a1c };
        inline const juce::Colour grilleB     { 0xff8c6a45 };
        inline const juce::Colour piping      { 0xffe9dcc0 };
        inline const juce::Colour jewelRed    { 0xffd8261c };
        inline const juce::Colour ledGreen    { 0xff53e07a };
        inline const juce::Colour ledAmber    { 0xffffc23a };
    }

    //==============================================================================
    /** Vector look & feel: cream chicken-head knobs on a copper control panel,
        touch-sized buttons. Everything is drawn with paths, so it scales to any
        iPad resolution. */
    class VoxLookAndFeel final : public juce::LookAndFeel_V4
    {
    public:
        VoxLookAndFeel();

        void drawRotarySlider (juce::Graphics&, int x, int y, int width, int height,
                               float sliderPosProportional, float rotaryStartAngle,
                               float rotaryEndAngle, juce::Slider&) override;

        void drawButtonBackground (juce::Graphics&, juce::Button&, const juce::Colour& backgroundColour,
                                   bool isMouseOverButton, bool isButtonDown) override;

        juce::Font getTextButtonFont (juce::TextButton&, int buttonHeight) override;

        juce::Label* createSliderTextBox (juce::Slider&) override;

        static juce::Font panelFont (float height, bool bold = true);
    };
}

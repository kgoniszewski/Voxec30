#include "VoxLookAndFeel.h"

namespace vox::gui
{
    VoxLookAndFeel::VoxLookAndFeel()
    {
        setColour (juce::ResizableWindow::backgroundColourId, Palette::tolex);
        setColour (juce::TextButton::buttonColourId,   juce::Colour (0xff2a2622));
        setColour (juce::TextButton::buttonOnColourId, Palette::copperDark);
        setColour (juce::TextButton::textColourOffId,  Palette::cream);
        setColour (juce::TextButton::textColourOnId,   Palette::cream);
        setColour (juce::Slider::textBoxTextColourId,  Palette::panelInk);
        setColour (juce::Slider::textBoxOutlineColourId, juce::Colours::transparentBlack);
        setColour (juce::Slider::textBoxBackgroundColourId, juce::Colours::transparentBlack);
        setColour (juce::Label::textColourId, Palette::cream);
        setColour (juce::PopupMenu::backgroundColourId, juce::Colour (0xff221e1a));
    }

    juce::Font VoxLookAndFeel::panelFont (float height, bool bold)
    {
        return juce::Font (juce::FontOptions (height, bold ? juce::Font::bold : juce::Font::plain));
    }

    //==============================================================================
    void VoxLookAndFeel::drawRotarySlider (juce::Graphics& g, int x, int y, int width, int height,
                                           float pos, float startAngle, float endAngle, juce::Slider& slider)
    {
        using namespace juce;

        const auto bounds = Rectangle<float> ((float) x, (float) y, (float) width, (float) height).reduced (2.0f);
        const float size  = jmin (bounds.getWidth(), bounds.getHeight());
        const auto  centre = bounds.getCentre();
        const float radius = size * 0.5f;
        const float angle  = startAngle + pos * (endAngle - startAngle);

        // --- scale: 0..10 tick marks printed on the panel ------------------------
        g.setColour (Palette::panelInk.withAlpha (0.85f));
        for (int i = 0; i <= 10; ++i)
        {
            const float a = startAngle + (float) i / 10.0f * (endAngle - startAngle);
            const float r1 = radius * 0.86f, r2 = radius * (i % 5 == 0 ? 0.99f : 0.94f);
            g.drawLine ({ centre.getPointOnCircumference (r1, a), centre.getPointOnCircumference (r2, a) },
                        jmax (1.0f, radius * (i % 5 == 0 ? 0.035f : 0.02f)));
        }

        // --- knob body (round skirt) -----------------------------------------------
        const float bodyR = radius * 0.62f;
        g.setColour (Palette::panelInk.withAlpha (0.35f));
        g.fillEllipse (Rectangle<float> (bodyR * 2.1f, bodyR * 2.1f).withCentre (centre.translated (0, radius * 0.05f)));

        ColourGradient skirt (Colour (0xff3a332c), centre.x, centre.y - bodyR,
                              Colour (0xff0d0b09), centre.x, centre.y + bodyR, false);
        g.setGradientFill (skirt);
        g.fillEllipse (Rectangle<float> (bodyR * 2.0f, bodyR * 2.0f).withCentre (centre));

        // --- chicken-head pointer (cream) -----------------------------------------
        Path head;
        const float len = radius * 0.80f, tail = radius * 0.42f, w = radius * 0.28f;
        head.startNewSubPath (0.0f, -len);
        head.cubicTo ( w * 0.55f, -len * 0.55f,  w, -tail * 0.2f,  w * 0.75f, tail * 0.55f);
        head.quadraticTo (0.0f, tail * 1.05f, -w * 0.75f, tail * 0.55f);
        head.cubicTo (-w, -tail * 0.2f, -w * 0.55f, -len * 0.55f, 0.0f, -len);
        head.closeSubPath();

        const auto xf = AffineTransform::rotation (angle).translated (centre);

        g.setColour (Palette::panelInk.withAlpha (0.45f));
        g.fillPath (head, xf.translated (radius * 0.03f, radius * 0.06f));

        ColourGradient cream (Palette::cream, centre.x - w, centre.y - len,
                              Colour (0xffbfae8c), centre.x + w, centre.y + tail, false);
        g.setGradientFill (cream);
        g.fillPath (head, xf);

        g.setColour (Colour (0xff6d5f48));
        g.strokePath (head, PathStrokeType (jmax (1.0f, radius * 0.02f)), xf);

        // pointer line
        g.setColour (Palette::panelInk);
        g.drawLine ({ centre.getPointOnCircumference (radius * 0.12f, angle),
                      centre.getPointOnCircumference (len * 0.92f, angle) },
                    jmax (1.5f, radius * 0.045f));

        // centre cap
        g.setColour (Colour (0xffcfc2a2));
        g.fillEllipse (Rectangle<float> (radius * 0.16f, radius * 0.16f).withCentre (centre));

        if (slider.isMouseButtonDown())
        {
            g.setColour (Palette::copperLight.withAlpha (0.25f));
            g.drawEllipse (Rectangle<float> (radius * 1.9f, radius * 1.9f).withCentre (centre), radius * 0.05f);
        }
    }

    //==============================================================================
    void VoxLookAndFeel::drawButtonBackground (juce::Graphics& g, juce::Button& b, const juce::Colour& bg,
                                               bool over, bool down)
    {
        using namespace juce;
        auto r = b.getLocalBounds().toFloat().reduced (1.5f);
        const float corner = r.getHeight() * 0.25f;

        auto base = b.getToggleState() ? Palette::copperDark : bg;
        if (down)      base = base.brighter (0.25f);
        else if (over) base = base.brighter (0.08f);

        g.setGradientFill (ColourGradient (base.brighter (0.15f), r.getTopLeft(), base.darker (0.25f), r.getBottomLeft(), false));
        g.fillRoundedRectangle (r, corner);
        g.setColour (Palette::copperLight.withAlpha (b.getToggleState() ? 0.9f : 0.35f));
        g.drawRoundedRectangle (r, corner, 1.5f);
    }

    juce::Font VoxLookAndFeel::getTextButtonFont (juce::TextButton&, int buttonHeight)
    {
        return panelFont (juce::jlimit (12.0f, 22.0f, (float) buttonHeight * 0.38f));
    }

    juce::Label* VoxLookAndFeel::createSliderTextBox (juce::Slider& s)
    {
        auto* l = LookAndFeel_V4::createSliderTextBox (s);
        l->setFont (panelFont (16.0f));
        l->setJustificationType (juce::Justification::centred);
        return l;
    }
}

#include "PluginEditor.h"

#if JucePlugin_Build_Standalone
 #include <juce_audio_utils/juce_audio_utils.h>
 #include <juce_audio_plugin_client/Standalone/juce_StandaloneFilterWindow.h>
#endif

using namespace vox::gui;

namespace
{
    juce::StandalonePluginHolder* standaloneHolder()
    {
       #if JucePlugin_Build_Standalone
        return juce::StandalonePluginHolder::getInstance();
       #else
        return nullptr;
       #endif
    }
}

//==============================================================================
VoxAC30Editor::AmpKnob::AmpKnob (juce::AudioProcessorValueTreeState& state, const juce::String& paramId,
                                 const juce::String& title, const juce::String& hint)
    : attachment (state, paramId, slider)
{
    slider.setSliderStyle (juce::Slider::RotaryHorizontalVerticalDrag);
    slider.setRotaryParameters (juce::degreesToRadians (-150.0f), juce::degreesToRadians (150.0f), true);
    slider.setTextBoxStyle (juce::Slider::TextBoxBelow, true, 64, 22);
    slider.setMouseDragSensitivity (260);                 // comfortable finger travel
    slider.setVelocityBasedMode (false);
    slider.setScrollWheelEnabled (true);
    slider.setPopupDisplayEnabled (false, false, nullptr);

    if (auto* p = state.getParameter (paramId))
        slider.setDoubleClickReturnValue (true, p->convertFrom0to1 (p->getDefaultValue()));

    name.setText (title, juce::dontSendNotification);
    name.setJustificationType (juce::Justification::centred);
    name.setColour (juce::Label::textColourId, Palette::panelInk);
    name.setInterceptsMouseClicks (false, false);

    subtitle.setText (hint, juce::dontSendNotification);
    subtitle.setJustificationType (juce::Justification::centred);
    subtitle.setColour (juce::Label::textColourId, Palette::panelInk.withAlpha (0.7f));
    subtitle.setInterceptsMouseClicks (false, false);

    addAndMakeVisible (name);
    addAndMakeVisible (subtitle);
    addAndMakeVisible (slider);
}

void VoxAC30Editor::AmpKnob::resized()
{
    auto r = getLocalBounds();
    const float h = (float) r.getHeight();

    name.setFont (VoxLookAndFeel::panelFont (juce::jlimit (14.0f, 30.0f, h * 0.09f)));
    name.setBounds (r.removeFromTop (juce::roundToInt (h * 0.13f)));

    subtitle.setFont (VoxLookAndFeel::panelFont (juce::jlimit (10.0f, 18.0f, h * 0.055f), false));
    subtitle.setBounds (r.removeFromBottom (juce::roundToInt (h * 0.08f)));

    slider.setTextBoxStyle (juce::Slider::TextBoxBelow, true,
                            juce::roundToInt (r.getWidth() * 0.6f), juce::roundToInt (h * 0.1f));
    slider.setBounds (r);
}

//==============================================================================
void VoxAC30Editor::LevelMeter::push (float peak) noexcept
{
    const float db   = juce::Decibels::gainToDecibels (peak, -60.0f);
    const float norm = juce::jlimit (0.0f, 1.0f, (db + 60.0f) / 60.0f);

    level = norm > level ? norm : level * 0.85f;

    if (norm >= hold) { hold = norm; holdFrames = 45; }
    else if (--holdFrames <= 0) hold = juce::jmax (0.0f, hold - 0.02f);

    repaint();
}

void VoxAC30Editor::LevelMeter::paint (juce::Graphics& g)
{
    auto r = getLocalBounds().toFloat();
    auto labelArea = r.removeFromLeft (r.getHeight() * 1.2f);

    g.setColour (Palette::cream.withAlpha (0.8f));
    g.setFont (VoxLookAndFeel::panelFont (r.getHeight() * 0.45f));
    g.drawText (text, labelArea, juce::Justification::centred);

    g.setColour (juce::Colour (0xff0a0908));
    g.fillRoundedRectangle (r, 4.0f);

    constexpr int segments = 24;
    const float segW = (r.getWidth() - 4.0f) / (float) segments;

    for (int i = 0; i < segments; ++i)
    {
        const float t  = (float) (i + 1) / (float) segments;
        const auto  on = t <= level;
        const auto  c  = t > 0.92f ? Palette::jewelRed : (t > 0.75f ? Palette::ledAmber : Palette::ledGreen);
        g.setColour (on ? c : c.withAlpha (0.12f));
        g.fillRoundedRectangle ({ r.getX() + 2.0f + (float) i * segW + 1.0f, r.getY() + 3.0f,
                                  segW - 2.0f, r.getHeight() - 6.0f }, 1.5f);
    }

    if (hold > 0.0f)
    {
        g.setColour (Palette::cream);
        g.fillRect (r.getX() + 2.0f + hold * (r.getWidth() - 4.0f) - 2.0f, r.getY() + 2.0f, 2.0f, r.getHeight() - 4.0f);
    }
}

//==============================================================================
VoxAC30Editor::VoxAC30Editor (VoxAC30Processor& p)
    : AudioProcessorEditor (p),
      processor (p),
      volumeKnob (p.getValueTreeState(), VoxParams::volume, "VOLUME", "Top Boost"),
      trebleKnob (p.getValueTreeState(), VoxParams::treble, "TREBLE"),
      bassKnob   (p.getValueTreeState(), VoxParams::bass,   "BASS"),
      cutKnob    (p.getValueTreeState(), VoxParams::cut,    "CUT", juce::String::fromUTF8 ("bright \xe2\x86\x92 dark")),
      masterKnob (p.getValueTreeState(), VoxParams::master, "MASTER"),
      cabAttachment (p.getValueTreeState(), VoxParams::cabOn, cabButton)
{
    setLookAndFeel (&lookAndFeel);

    for (auto* k : { &volumeKnob, &trebleKnob, &bassKnob, &cutKnob, &masterKnob })
        addAndMakeVisible (k);

    addAndMakeVisible (inputMeter);
    addAndMakeVisible (outputMeter);

    cabButton.setClickingTogglesState (true);
    addAndMakeVisible (cabButton);

    loadIrButton.onClick = [this] { chooseImpulseResponse(); };
    addAndMakeVisible (loadIrButton);

    defaultIrButton.onClick = [this]
    {
        processor.loadDefaultCabinetIR();
        updateCabinetLabel();
    };
    addAndMakeVisible (defaultIrButton);

    irLabel.setJustificationType (juce::Justification::centredLeft);
    irLabel.setColour (juce::Label::textColourId, Palette::cream.withAlpha (0.85f));
    addAndMakeVisible (irLabel);
    updateCabinetLabel();

    if (auto* holder = standaloneHolder())
    {
        // Audio device / channel routing (AXE I/O One: input 1 -> output 1).
        audioButton.onClick = [] { if (auto* h = standaloneHolder()) h->showAudioSettingsDialog(); };
        addAndMakeVisible (audioButton);

        // JUCE mutes the input of a fresh standalone app to avoid feedback with
        // the built-in mic. With an external interface the user unmutes here.
        inputMuted.referTo (holder->getMuteInputValue());
        inputMuted.addListener (this);
        inputButton.onClick = [this] { inputMuted.setValue (! (bool) inputMuted.getValue()); };
        addAndMakeVisible (inputButton);
        updateInputButton();

        // Guitar playing needs low round-trip latency: default to 128 samples
        // (~2.7 ms @ 48 kHz) unless the user already chose a small buffer.
        auto& deviceManager = holder->deviceManager;
        auto setup = deviceManager.getAudioDeviceSetup();
        if (setup.bufferSize <= 0 || setup.bufferSize > 256)
        {
            setup.bufferSize = 128;
            deviceManager.setAudioDeviceSetup (setup, true);
        }
    }

    setOpaque (true);
    setResizable (true, true);
    setResizeLimits (800, 560, 2732, 2048);
    setSize (1194, 834);                 // iPad Pro 11" landscape (points)

    startTimerHz (30);
}

VoxAC30Editor::~VoxAC30Editor()
{
    inputMuted.removeListener (this);
    setLookAndFeel (nullptr);
}

//==============================================================================
void VoxAC30Editor::timerCallback()
{
    inputMeter.push (processor.getInputPeak());

    const float out = processor.getOutputPeak();
    outputMeter.push (out);

    const float newPhase = juce::jlimit (0.0f, 1.0f, out * 1.5f);
    if (std::abs (newPhase - pilotPhase) > 0.02f)
    {
        pilotPhase = newPhase;
        repaint (panelArea.getSmallestIntegerContainer());
    }
}

void VoxAC30Editor::valueChanged (juce::Value&)
{
    updateInputButton();
}

void VoxAC30Editor::updateInputButton()
{
    const bool muted = (bool) inputMuted.getValue();
    inputButton.setButtonText (muted ? "INPUT: MUTED" : "INPUT: LIVE");
    inputButton.setToggleState (! muted, juce::dontSendNotification);
}

void VoxAC30Editor::updateCabinetLabel()
{
    irLabel.setText ("IR: " + processor.getCabinetName(), juce::dontSendNotification);
}

//==============================================================================
void VoxAC30Editor::chooseImpulseResponse()
{
    fileChooser = std::make_unique<juce::FileChooser> ("Select a cabinet impulse response",
                                                       vox::dsp::CabinetIR::getUserIRDirectory(),
                                                       "*.wav;*.aif;*.aiff;*.caf;*.flac");

    fileChooser->launchAsync (juce::FileBrowserComponent::openMode | juce::FileBrowserComponent::canSelectFiles,
                              [safeThis = juce::Component::SafePointer<VoxAC30Editor> (this)] (const juce::FileChooser& fc)
                              {
                                  if (safeThis == nullptr)
                                      return;

                                  const auto url = fc.getURLResult();
                                  if (! url.isEmpty())
                                      safeThis->importImpulseResponse (url);
                              });
}

void VoxAC30Editor::importImpulseResponse (const juce::URL& url)
{
    // On iPadOS the picker hands out a security-scoped URL. Copy the IR into the
    // app's own Documents folder so it is still accessible on the next launch.
    const auto irDir = vox::dsp::CabinetIR::getUserIRDirectory();
    const auto fileName = juce::File::createLegalFileName (juce::URL::removeEscapeChars (url.getFileName()));
    auto dest = irDir.getChildFile (fileName.isNotEmpty() ? fileName : juce::String ("impulse.wav"));

    bool ok = false;

    if (url.isLocalFile() && url.getLocalFile() == dest)
    {
        ok = processor.loadCabinetIR (dest);
    }
    else if (auto in = url.createInputStream (juce::URL::InputStreamOptions (juce::URL::ParameterHandling::inAddress)))
    {
        dest.deleteFile();
        {
            juce::FileOutputStream out (dest);
            ok = out.openedOk() && out.writeFromInputStream (*in, -1) > 0;
            out.flush();
        }
        ok = ok && processor.loadCabinetIR (dest);
    }

    if (! ok)
        juce::AlertWindow::showAsync (juce::MessageBoxOptions()
                                          .withIconType (juce::MessageBoxIconType::WarningIcon)
                                          .withTitle ("Impulse response")
                                          .withMessage ("This file could not be loaded as an impulse response.")
                                          .withButton ("OK"),
                                      nullptr);

    updateCabinetLabel();
}

//==============================================================================
void VoxAC30Editor::paint (juce::Graphics& g)
{
    // Static artwork (tolex, header, grille, toolbar) is rendered once per resize.
    g.drawImage (backgroundCache, getLocalBounds().toFloat());

    // The control panel is redrawn live (the pilot jewel follows the output level).
    paintPanel (g, panelArea);
}

void VoxAC30Editor::renderBackground()
{
    using namespace juce;

    const auto bounds = getLocalBounds();
    if (bounds.isEmpty())
        return;

    float scale = 2.0f;
    if (auto* display = Desktop::getInstance().getDisplays().getPrimaryDisplay())
        scale = (float) jmax (1.0, display->scale);

    backgroundCache = Image (Image::RGB, roundToInt ((float) bounds.getWidth() * scale),
                             roundToInt ((float) bounds.getHeight() * scale), true);
    Graphics g (backgroundCache);
    g.addTransform (AffineTransform::scale (scale));

    // --- tolex ---------------------------------------------------------------------
    g.fillAll (Palette::tolex);
    {
        Random rng (30);
        g.setColour (Colour (0xff221e1a));
        for (int i = 0; i < 2500; ++i)
            g.fillRect ((float) rng.nextInt (bounds.getWidth()), (float) rng.nextInt (bounds.getHeight()), 1.5f, 1.5f);
    }

    // --- header ----------------------------------------------------------------------
    {
        auto h = headerArea.reduced (headerArea.getHeight() * 0.15f, 0.0f);
        g.setColour (Palette::copperLight);
        g.setFont (VoxLookAndFeel::panelFont (headerArea.getHeight() * 0.5f));
        g.drawText ("VOXEC 30", h, Justification::centredLeft);

        g.setColour (Palette::cream.withAlpha (0.7f));
        g.setFont (VoxLookAndFeel::panelFont (headerArea.getHeight() * 0.26f, false));
        g.drawText (String::fromUTF8 ("Top Boost  \xc2\xb7  ECC83 preamp  \xc2\xb7  4 \xc3\x97 EL84 Class AB  \xc2\xb7  GZ34  \xc2\xb7  4\xc3\x97 oversampling"),
                    h, Justification::centredRight);
    }

    paintGrille (g, grilleArea);

    // --- toolbar --------------------------------------------------------------------
    g.setColour (Colour (0xff0d0c0b));
    g.fillRect (toolbarArea);
    g.setColour (Palette::copperDark.withAlpha (0.6f));
    g.fillRect (toolbarArea.withHeight (1.5f));
}

void VoxAC30Editor::paintPanel (juce::Graphics& g, juce::Rectangle<float> r) const
{
    using namespace juce;

    const float corner = r.getHeight() * 0.04f;

    // piping frame
    g.setColour (Palette::piping);
    g.fillRoundedRectangle (r.expanded (3.0f), corner + 3.0f);

    // brushed copper
    ColourGradient copper (Palette::copperLight, r.getX(), r.getY(),
                           Palette::copperDark, r.getX(), r.getBottom(), false);
    copper.addColour (0.45, Colour (0xffc48a50));
    copper.addColour (0.55, Colour (0xffe0b27a));
    g.setGradientFill (copper);
    g.fillRoundedRectangle (r, corner);

    Random rng (7);
    for (int i = 0; i < 120; ++i)
    {
        const float y = r.getY() + rng.nextFloat() * r.getHeight();
        g.setColour (Palette::panelInk.withAlpha (0.03f + 0.04f * rng.nextFloat()));
        g.drawHorizontalLine ((int) y, r.getX() + corner, r.getRight() - corner);
    }

    // section lettering
    g.setColour (Palette::panelInk);
    g.setFont (VoxLookAndFeel::panelFont (r.getHeight() * 0.06f));
    const auto top = r.withHeight (r.getHeight() * 0.11f).reduced (r.getWidth() * 0.03f, 0.0f);
    g.drawText ("TOP BOOST", top, Justification::centredLeft);
    g.drawText ("MASTER SECTION", top, Justification::centredRight);

    // separator between channel and master section (between CUT and MASTER)
    const float sepX = masterKnob.getX() - r.getWidth() * 0.012f;
    g.setColour (Palette::panelInk.withAlpha (0.4f));
    g.drawLine (sepX, r.getY() + r.getHeight() * 0.18f, sepX, r.getBottom() - r.getHeight() * 0.12f, 2.0f);

    // jewel pilot lamp (glows with the output level)
    const float jr = r.getHeight() * 0.075f;
    const auto jc = Point<float> (r.getRight() - r.getWidth() * 0.045f, r.getCentreY());
    g.setColour (Palette::jewelRed.withAlpha (0.25f + 0.3f * pilotPhase));
    g.fillEllipse (Rectangle<float> (jr * 3.2f, jr * 3.2f).withCentre (jc));
    g.setColour (Palette::panelInk);
    g.fillEllipse (Rectangle<float> (jr * 2.3f, jr * 2.3f).withCentre (jc));
    ColourGradient jewel (Palette::jewelRed.brighter (0.6f + 0.4f * pilotPhase), jc.x - jr * 0.4f, jc.y - jr * 0.4f,
                          Palette::jewelRed.darker (0.6f), jc.x + jr, jc.y + jr, true);
    g.setGradientFill (jewel);
    g.fillEllipse (Rectangle<float> (jr * 2.0f, jr * 2.0f).withCentre (jc));

    g.setColour (Palette::panelInk);
    g.setFont (VoxLookAndFeel::panelFont (r.getHeight() * 0.045f));
    g.drawText ("ON", Rectangle<float> (jr * 4.0f, jr).withCentre (jc.translated (0.0f, jr * 1.9f)), Justification::centred);
}

void VoxAC30Editor::paintGrille (juce::Graphics& g, juce::Rectangle<float> r) const
{
    using namespace juce;

    Graphics::ScopedSaveState save (g);

    // piping border
    g.setColour (Palette::piping);
    g.fillRoundedRectangle (r.expanded (3.0f), 10.0f);
    g.setColour (Palette::grilleA);
    g.fillRoundedRectangle (r, 8.0f);

    g.reduceClipRegion (r.toNearestInt());

    // diamond weave
    const float cell = jmax (10.0f, r.getHeight() * 0.06f);
    Path diamonds;
    for (float y = r.getY() - cell; y < r.getBottom() + cell; y += cell)
        for (float x = r.getX() - cell; x < r.getRight() + cell; x += cell)
        {
            const float ox = (std::fmod ((y - r.getY()) / cell, 2.0f) < 1.0f) ? 0.0f : cell * 0.5f;
            const Point<float> c (x + ox, y);
            diamonds.startNewSubPath (c.translated (0, -cell * 0.42f));
            diamonds.lineTo (c.translated (cell * 0.42f, 0));
            diamonds.lineTo (c.translated (0, cell * 0.42f));
            diamonds.lineTo (c.translated (-cell * 0.42f, 0));
            diamonds.closeSubPath();
        }

    g.setColour (Palette::grilleB.withAlpha (0.55f));
    g.strokePath (diamonds, PathStrokeType (cell * 0.12f));

    // vignette
    g.setGradientFill (ColourGradient (Palette::grilleA.withAlpha (0.0f), r.getCentre(),
                                       juce::Colours::black.withAlpha (0.55f), r.getTopLeft(), true));
    g.fillRect (r);

    // badge
    const float bw = r.getWidth() * 0.2f, bh = bw * 0.32f;
    const auto badge = Rectangle<float> (bw, bh).withCentre ({ r.getCentreX(), r.getY() + r.getHeight() * 0.32f });
    g.setGradientFill (ColourGradient (Palette::cream, badge.getX(), badge.getY(),
                                       Colour (0xffb8a888), badge.getX(), badge.getBottom(), false));
    g.fillRoundedRectangle (badge, bh * 0.18f);
    g.setColour (Palette::panelInk);
    g.drawRoundedRectangle (badge.reduced (bh * 0.08f), bh * 0.14f, jmax (1.0f, bh * 0.04f));
    g.setFont (VoxLookAndFeel::panelFont (bh * 0.62f));
    g.drawText ("VOXEC", badge, Justification::centred);
}

//==============================================================================
void VoxAC30Editor::resized()
{
    auto r = getLocalBounds().toFloat();
    const float W = r.getWidth(), H = r.getHeight();
    const float margin = juce::jmax (8.0f, W * 0.02f);

    headerArea  = r.removeFromTop (H * 0.085f);
    toolbarArea = r.removeFromBottom (juce::jlimit (56.0f, 110.0f, H * 0.11f));
    r.reduce (margin, margin * 0.5f);
    panelArea   = r.removeFromTop (r.getHeight() * 0.56f);
    r.removeFromTop (margin * 0.8f);
    grilleArea  = r;

    // --- knobs: 3 channel knobs + gap + CUT + gap + MASTER; jewel on the right -----
    auto knobRow = panelArea.reduced (panelArea.getWidth() * 0.02f, panelArea.getHeight() * 0.1f)
                            .withTrimmedTop (panelArea.getHeight() * 0.03f);
    knobRow.removeFromRight (panelArea.getWidth() * 0.09f);    // pilot lamp

    const float slot = knobRow.getWidth() / 5.4f;
    auto place = [&] (AmpKnob& k, float gapBefore)
    {
        knobRow.removeFromLeft (gapBefore);
        k.setBounds (knobRow.removeFromLeft (slot).toNearestInt());
    };

    place (volumeKnob, 0.0f);
    place (trebleKnob, 0.0f);
    place (bassKnob,   0.0f);
    place (cutKnob,    slot * 0.1f);
    place (masterKnob, slot * 0.3f);

    // --- toolbar ------------------------------------------------------------------------
    auto tb = toolbarArea.reduced (margin, toolbarArea.getHeight() * 0.18f).toNearestInt();
    const int bh = tb.getHeight();
    const int gap = juce::roundToInt (margin * 0.5f);

    auto meters = tb.removeFromLeft (juce::roundToInt (W * 0.22f));
    inputMeter.setBounds  (meters.removeFromTop (bh / 2).reduced (0, 2));
    outputMeter.setBounds (meters.reduced (0, 2));
    tb.removeFromLeft (gap);

    auto button = [&] (juce::Component& c, float widthFactor)
    {
        if (! c.isVisible()) return;
        c.setBounds (tb.removeFromLeft (juce::roundToInt ((float) bh * widthFactor)));
        tb.removeFromLeft (gap);
    };

    button (inputButton,     2.6f);
    button (audioButton,     2.2f);
    button (cabButton,       1.4f);
    button (loadIrButton,    1.9f);
    button (defaultIrButton, 2.2f);

    irLabel.setFont (VoxLookAndFeel::panelFont (juce::jlimit (12.0f, 18.0f, (float) bh * 0.32f), false));
    irLabel.setBounds (tb);

    renderBackground();
}

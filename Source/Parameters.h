#pragma once

#include <juce_audio_processors/juce_audio_processors.h>

//==============================================================================
/** Parameter IDs and the APVTS layout of the AC30 Top Boost model.

    All knobs use the 0..10 scale printed on the original control panel.
*/
namespace VoxParams
{
    inline constexpr auto volume  = "volume";   // Top Boost (Brilliant) channel volume
    inline constexpr auto treble  = "treble";   // Top Boost treble
    inline constexpr auto bass    = "bass";     // Top Boost bass
    inline constexpr auto cut     = "cut";      // Tone Cut - clockwise REMOVES treble (as on the original)
    inline constexpr auto master  = "master";   // Master volume (pre phase inverter, AC30CC style)
    inline constexpr auto cabOn   = "cabOn";    // Cabinet IR on/off

    inline constexpr int version = 1;

    inline juce::AudioProcessorValueTreeState::ParameterLayout createLayout()
    {
        using namespace juce;

        auto knob = [] (const char* id, const char* name, float def)
        {
            return std::make_unique<AudioParameterFloat> (
                ParameterID { id, version }, name,
                NormalisableRange<float> { 0.0f, 10.0f, 0.01f }, def,
                AudioParameterFloatAttributes{}.withStringFromValueFunction (
                    [] (float v, int) { return String (v, 1); }));
        };

        AudioProcessorValueTreeState::ParameterLayout layout;
        layout.add (knob (volume, "Volume",      5.0f));
        layout.add (knob (treble, "Treble",      6.0f));
        layout.add (knob (bass,   "Bass",        4.0f));
        layout.add (knob (cut,    "Tone Cut",    3.0f));
        layout.add (knob (master, "Master",      6.0f));
        layout.add (std::make_unique<AudioParameterBool> (ParameterID { cabOn, version }, "Cabinet", true));
        return layout;
    }
}

#pragma once

#include <juce_audio_formats/juce_audio_formats.h>
#include <juce_dsp/juce_dsp.h>

#include <atomic>

namespace vox::dsp
{
    //==============================================================================
    /** Speaker cabinet simulation (Celestion Alnico Blue 2x12 by default) using
        juce::dsp::Convolution.

        Threading model:
        - load*() functions are called on the MESSAGE thread only. JUCE's
          Convolution hands the new IR to a background thread, then to the audio
          thread through a lock-free FIFO and cross-fades to it, so process()
          never blocks and never allocates.
        - process() is called on the audio thread.
    */
    class CabinetIR
    {
    public:
        CabinetIR();

        void prepare (const juce::dsp::ProcessSpec& spec);
        void reset() noexcept;

        /** Mono, in place. */
        void process (float* samples, int numSamples) noexcept;

        // --- message thread -------------------------------------------------------
        /** Loads the IR embedded in the app bundle (Resources/IR/AlnicoBlue_2x12.wav). */
        bool loadDefault();

        /** Loads any WAV/AIFF/CAF impulse response. */
        bool loadFromFile (const juce::File& file);

        juce::String getCurrentName() const   { return currentName; }
        juce::File   getCurrentFile() const   { return currentFile; }

        /** Directory inside the app sandbox where user IRs are stored (iOS: Documents/IR). */
        static juce::File getUserIRDirectory();

    private:
        juce::dsp::Convolution convolution;
        std::atomic<bool> hasImpulse { false };
        juce::String currentName;
        juce::File currentFile;
    };
}

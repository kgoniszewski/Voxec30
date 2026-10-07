#pragma once

#include <juce_dsp/juce_dsp.h>

#include "DspUtils.h"
#include "PowerAmpEL84.h"
#include "PowerSupplyGZ34.h"
#include "TopBoostToneStack.h"
#include "TriodeModel.h"

namespace vox::dsp
{
    //==============================================================================
    /** Complete Vox AC30 Top Boost signal path (without the speaker cabinet).

        Block diagram (everything between [OS] runs 4x oversampled):

          in -> DC block -> [OS
             V1   ECC83 input stage (68k stopper, 1M leak, grid conduction)
             V2a  ECC83 Top Boost gain stage (bypassed cathode, coupling-cap blocking)
             V2b  ECC83 cathode follower (asymmetric grid-current / cut-off limiting)
             Top Boost Treble/Bass passive network (3rd order, interactive)
             Volume pot (log)
             V3   ECC83 mixer stage (unbypassed cathode)
             Master pot (log)
             PI   ECC83 long-tailed pair (82k/100k plate load imbalance)
             Tone Cut (RC across the PI plates; clockwise = darker)
             4 x EL84 push-pull Class AB, cathode bias, no NFB
             GZ34 rectifier + reservoir sag feeding B+ back into the stages
          OS] -> output transformer + speaker-impedance interaction -> out

        process() is real-time safe: no allocation, no locks, no system calls.
    */
    class AC30Circuit
    {
    public:
        struct Controls
        {
            float volume = 5.0f, treble = 6.0f, bass = 4.0f, cut = 3.0f, master = 6.0f;   // 0..10
        };

        AC30Circuit();

        void prepare (double sampleRate, int maximumBlockSize);
        void reset() noexcept;

        /** Thread-safe to call from the audio thread right before process(). */
        void setControls (const Controls& c) noexcept { controls = c; }

        /** Mono, in place. */
        void process (float* samples, int numSamples) noexcept;

        int getLatencySamples() const noexcept;

        static constexpr int oversamplingOrder  = 2;     // 2^2 = 4x
        static constexpr int oversamplingFactor = 1 << oversamplingOrder;

    private:
        void processChunk (float* samples, int numSamples) noexcept;
        void updateCutFilter (float cut01) noexcept;

        juce::dsp::Oversampling<float> oversampling;

        double baseRate = 48000.0, osRate = 192000.0;
        Controls controls;

        // --- oversampled section ---------------------------------------------
        TriodeStage v1, v2a, v3;
        TopBoostToneStack toneStack;
        PowerAmpEL84 powerAmp;
        PowerSupplyGZ34 psu;

        Ramp volumeGain, masterGain;
        float trebleSm = 0.6f, bassSm = 0.4f, cutSm = 0.3f, cutApplied = -1.0f;

        // Tone Cut: first-order shelving low-pass, one per PI output
        float cutB0 = 1.0f, cutB1 = 0.0f, cutA1 = 0.0f;
        float cutStateA = 0.0f, cutStateB = 0.0f;

        // --- base-rate post section ------------------------------------------
        OnePoleHP inputDcBlock, outputDcBlock;
        Biquad otLowCut, speakerResonance, voiceCoilRise, otHighCut;

        // Calibration of the circuit's voltage domain
        static constexpr float inputVoltsPerFullScale = 1.0f;   // 0 dBFS from the interface = 1 V peak at the grid
        static constexpr float v1ToV2Divider          = 0.025f;  // Brilliant-channel coupling / mixing network
        static constexpr float mixerNetwork           = 0.5f;   // 470k/470k channel mixing resistors
        static constexpr float masterNetwork          = 0.1f;    // master pot + PI input divider
        static constexpr float outputTrim             = 0.35f;
    };
}

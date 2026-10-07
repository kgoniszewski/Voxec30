#include "AC30Circuit.h"

namespace vox::dsp
{
    namespace
    {
        constexpr int chunkSize = 32;   // parameter-smoothing granularity (base-rate samples)

        /** V2b cathode follower driving the tone stack.
            Positive excursions are limited by grid current (grid can't rise above
            the cathode), negative ones by cut-off much later -> asymmetric,
            even-order rich clipping typical of a CF-driven tone stack. */
        inline float cathodeFollower (float x, float supply) noexcept
        {
            const float posLimit = 60.0f  * supply;
            const float negLimit = 120.0f * supply;
            return x >= 0.0f ? posLimit * softClip (x / posLimit)
                             : negLimit * softClip (x / negLimit);
        }

        /** Long-tailed-pair phase inverter (ECC83). The tail current is shared,
            so each plate follows a tanh of the differential input. The AC30
            uses unequal plate loads (82k / 100k) -> imperfect balance -> some
            even harmonics survive the push-pull stage. */
        struct PhaseInverterOut { float a, b; };

        inline PhaseInverterOut phaseInverter (float x, float supply) noexcept
        {
            constexpr float vSat   = 3.2f;          // differential input for tanh "knee"
            constexpr float swingA = 80.0f;         // 0.5 * Itail * 100k
            constexpr float swingB = 80.0f * 0.82f; // 82k plate
            const float t = std::tanh (x / vSat);
            return { -swingA * supply * t, swingB * supply * t };
        }
    }

    //==============================================================================
    AC30Circuit::AC30Circuit()
        : oversampling (1, (size_t) oversamplingOrder,
                        juce::dsp::Oversampling<float>::filterHalfBandPolyphaseIIR,
                        true,    // max quality
                        true)    // integer latency
    {
    }

    void AC30Circuit::prepare (double sampleRate, int maximumBlockSize)
    {
        baseRate = sampleRate;
        osRate   = sampleRate * oversamplingFactor;

        oversampling.initProcessing ((size_t) std::max (maximumBlockSize, chunkSize));

        // --- preamp valves (component values from the AC30 Top Boost circuit) --
        TriodeStage::Config c1;                     // V1: input stage
        c1.supplyVolts     = 250.0;
        c1.plateResistor   = 220e3;
        c1.cathodeResistor = 1.5e3;
        c1.cathodeCap      = 25e-6;
        c1.couplingCap     = 0.0;                   // guitar is DC-coupled to the grid
        c1.gridLeak        = 1.0e6;
        c1.gridStopper     = 68e3;
        v1.prepare (c1, osRate);

        TriodeStage::Config c2 = c1;                // V2a: Top Boost gain stage
        c2.supplyVolts     = 260.0;
        c2.plateResistor   = 220e3;
        c2.cathodeResistor = 1.8e3;
        c2.cathodeCap      = 25e-6;
        c2.couplingCap     = 47e-9;
        c2.gridLeak        = 1.0e6;
        c2.gridStopper     = 100e3;
        v2a.prepare (c2, osRate);

        TriodeStage::Config c3 = c1;                // V3: mixer stage
        c3.supplyVolts     = 270.0;
        c3.plateResistor   = 220e3;
        c3.cathodeResistor = 1.5e3;
        c3.cathodeCap      = 0.0;                   // unbypassed
        c3.couplingCap     = 22e-9;
        c3.gridLeak        = 1.0e6;
        c3.gridStopper     = 470e3 / 2.0;           // mixing resistors
        v3.prepare (c3, osRate);

        toneStack.prepare (osRate);
        powerAmp.prepare (osRate);
        psu.prepare (osRate, powerAmp.getIdleSupplyCurrent());

        // --- base-rate filters --------------------------------------------------
        inputDcBlock.setCutoff (8.0, baseRate);
        outputDcBlock.setCutoff (10.0, baseRate);

        // No global NFB: output impedance is high, so the amp "sees" the
        // speaker's impedance curve -> resonance bump and HF rise.
        otLowCut.setHighPass (baseRate, 45.0, 0.6);
        speakerResonance.setPeak (baseRate, 95.0, 1.4, 3.5);
        voiceCoilRise.setHighShelf (baseRate, 3500.0, 0.7, 3.0);
        otHighCut.setLowPass (baseRate, std::min (14000.0, 0.45 * baseRate), 0.7);

        reset();
    }

    void AC30Circuit::reset() noexcept
    {
        oversampling.reset();
        v1.reset(); v2a.reset(); v3.reset();
        toneStack.reset();
        powerAmp.reset();
        psu.reset();

        trebleSm = controls.treble / 10.0f;
        bassSm   = controls.bass   / 10.0f;
        cutSm    = controls.cut    / 10.0f;
        toneStack.setControls (trebleSm, bassSm);
        cutApplied = -1.0f;
        updateCutFilter (cutSm);
        cutStateA = cutStateB = 0.0f;

        volumeGain.reset (audioTaper (controls.volume / 10.0f));
        masterGain.reset (audioTaper (controls.master / 10.0f));

        inputDcBlock.reset(); outputDcBlock.reset();
        otLowCut.reset(); speakerResonance.reset(); voiceCoilRise.reset(); otHighCut.reset();
    }

    int AC30Circuit::getLatencySamples() const noexcept
    {
        return (int) oversampling.getLatencyInSamples();
    }

    //==============================================================================
    void AC30Circuit::updateCutFilter (float cut01) noexcept
    {
        if (std::abs (cut01 - cutApplied) < 1.0e-4f)
            return;

        cutApplied = cut01;

        // Cut pot + cap across the PI plates, seen per side as a shunt branch
        // (Rcut/2 + 2C) behind the PI's output impedance. Clockwise -> Rcut -> 0.
        constexpr double rSource = 33e3;
        constexpr double cEff    = 4.7e-9;
        const double rot  = std::clamp ((double) cut01, 0.0, 1.0);
        const double rCut = 500e3 * (1.0 - rot) * (1.0 - rot) + 10.0;

        const double tz = cEff * rCut;
        const double tp = cEff * (rSource + rCut);
        const double c  = 2.0 * osRate;

        const double norm = 1.0 / (1.0 + c * tp);
        cutB0 = (float) ((1.0 + c * tz) * norm);
        cutB1 = (float) ((1.0 - c * tz) * norm);
        cutA1 = (float) ((1.0 - c * tp) * norm);
    }

    void AC30Circuit::process (float* samples, int numSamples) noexcept
    {
        for (int start = 0; start < numSamples; start += chunkSize)
            processChunk (samples + start, std::min (chunkSize, numSamples - start));
    }

    void AC30Circuit::processChunk (float* samples, int numSamples) noexcept
    {
        // --- control smoothing (once per chunk) -----------------------------------
        constexpr float approach = 0.25f;
        trebleSm += approach * (controls.treble / 10.0f - trebleSm);
        bassSm   += approach * (controls.bass   / 10.0f - bassSm);
        cutSm    += approach * (controls.cut    / 10.0f - cutSm);
        toneStack.setControls (trebleSm, bassSm);
        updateCutFilter (cutSm);

        const int osSamples = numSamples * oversamplingFactor;
        volumeGain.begin (audioTaper (controls.volume / 10.0f), osSamples);
        masterGain.begin (audioTaper (controls.master / 10.0f), osSamples);

        // --- input conditioning ---------------------------------------------------
        for (int i = 0; i < numSamples; ++i)
            samples[i] = inputDcBlock.process (samples[i]) * inputVoltsPerFullScale;

        // --- oversampled valve circuit -----------------------------------------------
        float* channels[] = { samples };
        juce::dsp::AudioBlock<float> block (channels, 1, (size_t) numSamples);
        auto os = oversampling.processSamplesUp (block);
        float* x = os.getChannelPointer (0);

        for (int i = 0; i < osSamples; ++i)
        {
            const float powerSupply  = psu.getPowerFactor();
            const float preampSupply = psu.getPreampFactor();

            // Preamp
            float v = v1.process (x[i], preampSupply);
            v = v2a.process (v * v1ToV2Divider, preampSupply);
            v = cathodeFollower (v, preampSupply);
            v = toneStack.process (v);
            v *= volumeGain.next();
            v = v3.process (v * mixerNetwork, preampSupply);
            v *= masterGain.next() * masterNetwork;

            // Phase inverter + Tone Cut
            const auto inv = phaseInverter (v, preampSupply);

            const float ya = cutB0 * inv.a + cutStateA;
            cutStateA = cutB1 * inv.a - cutA1 * ya;
            const float yb = cutB0 * inv.b + cutStateB;
            cutStateB = cutB1 * inv.b - cutA1 * yb;

            // Power stage + rectifier sag
            const float out = powerAmp.process (ya, yb, powerSupply);
            psu.process (powerAmp.getSupplyCurrent());

            x[i] = sanitise (out);
        }

        volumeGain.end();
        masterGain.end();

        oversampling.processSamplesDown (block);

        // --- output transformer / speaker interaction (linear, base rate) -------------
        for (int i = 0; i < numSamples; ++i)
        {
            float y = samples[i];
            y = otLowCut.process (y);
            y = speakerResonance.process (y);
            y = voiceCoilRise.process (y);
            y = otHighCut.process (y);
            samples[i] = outputDcBlock.process (y * outputTrim);
        }
    }
}

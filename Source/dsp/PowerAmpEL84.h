#pragma once

namespace vox::dsp
{
    //==============================================================================
    /** EL84 pentode, Koren-style fit with screen voltage as the controlling
        "plate" term (pentode plate current is almost independent of Va above
        the knee).

            E1 = (Vg2 / Kp) * ln (1 + exp (Kp * (1/mu + Vg1k / Vg2)))
            Ia = E1^Ex / Kg1                                             [A]

        Constants are fitted so that a cathode-biased AC30 output stage idles at
        ~45-48 mA per valve with Vk ~ 9.5 V (330 V B+), peaking at ~170 mA.
    */
    struct EL84Pentode
    {
        double mu = 19.0, ex = 1.35, kg1 = 240.0, kp = 200.0;

        double plateCurrent (double vgk, double vg2) const noexcept;
        float  plateCurrentFast (float vgk, float vg2) const noexcept;
    };

    //==============================================================================
    /** AC30 output stage: 4 x EL84, push-pull, cathode-biased Class AB,
        NO global negative feedback.

        - Each half = 2 x EL84 in parallel, driven through its own coupling cap
          / grid leak / grid stopper with grid-conduction (blocking distortion).
        - Shared, bypassed 50 R cathode resistor: the cathode voltage follows the
          average current with the Rk*Ck time constant -> under heavy drive the
          valves bias colder, crossover distortion and "squash" increase. This
          is the defining dynamic of the AC30.
        - Plate swing is limited by the instantaneous (sagging) B+ minus the
          pentode knee voltage.
        - Output = difference current through the output transformer primary,
          normalised so that full (unsagged) power is +-1.
    */
    class PowerAmpEL84
    {
    public:
        void prepare (double sampleRate);
        void reset() noexcept;

        /** @param gridA, gridB   drive voltages from the phase inverter (AC)
            @param supplyFactor   B+(t) / B+(nominal) from the GZ34 model     */
        float process (float gridA, float gridB, float supplyFactor) noexcept;

        /** Current drawn from the HT supply at the last step (A), for sag. */
        double getSupplyCurrent() const noexcept { return supplyCurrent; }

        /** Idle supply current of the whole amp (A). */
        double getIdleSupplyCurrent() const noexcept { return idleSupplyCurrent; }

        double getIdleCathodeVoltage() const noexcept { return vkIdle; }

        static constexpr double bPlusNominal = 330.0;

    private:
        struct GridInput
        {
            float cap = 0.0f;
            float process (float x, float vk, float coeffLeak, float coeffGrid, float alpha) noexcept;
        };

        EL84Pentode tube;
        GridInput gridInA, gridInB;

        float vk = 0.0f;
        double vkIdle = 0.0, supplyCurrent = 0.0, idleSupplyCurrent = 0.0;
        float cathodeCoeff = 0.0f, capLeak = 0.0f, capGrid = 0.0f, gridAlpha = 0.0f;

        static constexpr double rk          = 50.0;     // shared cathode resistor (4 valves)
        static constexpr double ck          = 250e-6;   // cathode bypass
        static constexpr double screenRatio = 0.10;     // Ig2 / Ia
        static constexpr double rLoad       = 1.0e3;    // reflected load per half-primary pair
        static constexpr double vKnee       = 40.0;     // pentode knee voltage
        static constexpr double preampDraw  = 0.012;    // preamp + PI HT current (A)
        static constexpr double screenDrop  = 0.95;     // Vg2 / B+
    };
}

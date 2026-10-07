#pragma once

#include <array>
#include <vector>

namespace vox::dsp
{
    //==============================================================================
    /** Norman Koren's phenomenological triode model.

            E1 = (Vpk / Kp) * ln (1 + exp (Kp * (1/mu + Vgk / sqrt (Kvb + Vpk^2))))
            Ip = (E1^Ex / Kg1) * (1 + sgn (E1))                    [A]

        Default constants are Koren's published fit for the 12AX7 / ECC83.
    */
    struct KorenTriode
    {
        double mu = 100.0, ex = 1.4, kg1 = 1060.0, kp = 600.0, kvb = 300.0;

        double plateCurrent (double vgk, double vpk) const noexcept;
    };

    //==============================================================================
    /** A common-cathode ECC83 gain stage, solved as a static nonlinearity + slow
        dynamic states (a "quasi-static" circuit model):

        - The plate load line  Vp = B+ - Rp * Ip(Vgk, Vpk)  is solved offline with a
          bracketed Newton/bisection solver and stored in a dense lookup table
          (no iterative solving on the audio thread).
        - Bypassed cathode (Ck > 0): the cathode voltage Vk = Ip * Rk follows the
          plate current with the Rk*Ck time constant -> bias shift / compression.
          Unbypassed cathode (Ck == 0): Rk degeneration is solved inside the table.
        - Input network: coupling cap Cc + grid-leak Rg + grid stopper Rs, with a
          smooth grid-conduction diode. When the grid is driven positive it draws
          current, charges Cc and shifts the operating point ("blocking"
          distortion / the characteristic AC30 "sag-on-attack" in the preamp).
        - Supply sag is applied by voltage-scaling the table (Koren equations are
          close to homogeneous in the electrode voltages).

        Input and output are in volts (AC components). The stage is inverting,
        exactly like the real circuit.
    */
    class TriodeStage
    {
    public:
        struct Config
        {
            double supplyVolts      = 265.0;   // B+ at the top of the plate resistor
            double plateResistor    = 220e3;
            double cathodeResistor  = 1.5e3;
            double cathodeCap       = 25e-6;   // 0 = unbypassed (local feedback)
            double couplingCap      = 22e-9;   // 0 = DC coupled input (first stage)
            double gridLeak         = 1.0e6;
            double gridStopper      = 68e3;
            double gridCathodeOn    = 1.5e3;   // forward resistance of the grid "diode"
            KorenTriode tube {};
        };

        void prepare (const Config& cfg, double sampleRate);
        void reset() noexcept;

        /** @param x            input voltage (AC) at the coupling capacitor
            @param supplyScale  B+(t) / B+(nominal), 1 = no sag                 */
        float process (float x, float supplyScale = 1.0f) noexcept;

        /** Quiescent plate voltage (for diagnostics / tests). */
        double getQuiescentPlate() const noexcept { return vpQuiescent; }

        /** Small-signal voltage gain at the operating point (for diagnostics). */
        double getSmallSignalGain() const noexcept { return smallSignalGain; }

    private:
        static constexpr int tableSize = 4096;
        static constexpr float uMin = -12.0f, uMax = 8.0f;

        struct Entry { float vp, ip; };

        double solvePlateCurrent (double u, double rkInLoop) const noexcept;
        Entry lookup (float u) const noexcept;

        Config config;
        std::vector<Entry> table;
        float tableScale = 0.0f;
        double vpQuiescent = 0.0, ipQuiescent = 0.0, vkQuiescent = 0.0, smallSignalGain = 0.0;
        bool bypassed = true;

        // dynamic state
        float capCharge = 0.0f;      // voltage across the input coupling cap
        float vk = 0.0f;             // cathode voltage (bypassed stages)
        float capCoeffLeak = 0.0f, capCoeffGrid = 0.0f, cathodeCoeff = 0.0f;
        float gridAlpha = 0.0f;
    };
}

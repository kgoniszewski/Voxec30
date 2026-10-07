#pragma once

#include <algorithm>
#include <cmath>

namespace vox::dsp
{
    //==============================================================================
    /** GZ34 / 5AR4 valve rectifier + reservoir capacitor ("sag").

        Model (per oversampled step, forward Euler):

            Ich   = max (0, Vpk - Vb) / Rrect(Ich)       rectifier can only CHARGE the cap
            C dVb/dt = Ich - Iload

        The GZ34 is a vacuum diode: its forward resistance is current dependent
        (Child-Langmuir, I ~ V^1.5 => R falls as current rises). Because the diode
        cannot discharge the reservoir, recovery is governed by the load and
        attack by Rrect*C, which gives the asymmetric, "breathing" compression of
        a cathode-biased AC30 pushed hard. Mains ripple is not modelled (it is
        filtered by the choke/second stage before reaching the preamp).

        The model returns a normalised supply factor (Vb / Vb_idle) for the
        power stage, and a slower, more heavily filtered factor for the preamp
        and phase inverter rails (RC decoupling chain).
    */
    class PowerSupplyGZ34
    {
    public:
        void prepare (double sampleRate, double idleCurrent)
        {
            dt         = 1.0 / sampleRate;
            iIdle      = idleCurrent;
            // Choose the transformer peak so that the idle B+ equals vNominal.
            vPeak      = vNominal + iIdle * rectResistance (iIdle);
            preampCoeff = 1.0 - std::exp (-dt / 0.060);   // ~60 ms decoupling RC chain
            reset();
        }

        void reset() noexcept
        {
            vb = vNominal;
            preampFactor = 1.0;
        }

        /** Advance one step with the instantaneous load current (amps). */
        void process (double loadCurrent) noexcept
        {
            const double headroom = vPeak - vb;
            double iCharge = 0.0;

            if (headroom > 0.0)
            {
                // Two fixed-point iterations of I = dV / R(I) are plenty here.
                iCharge = headroom / rectResistance (iIdle);
                iCharge = headroom / rectResistance (iCharge);
            }

            vb += dt / reservoirCap * (iCharge - std::max (0.0, loadCurrent));
            vb  = std::clamp (vb, 0.5 * vNominal, vPeak);

            preampFactor += preampCoeff * (vb / vNominal - preampFactor);
        }

        float getPowerFactor()  const noexcept { return (float) (vb / vNominal); }
        float getPreampFactor() const noexcept { return (float) preampFactor; }
        double getVoltage()     const noexcept { return vb; }

        static constexpr double vNominal = 330.0;   // idle B+ on the EL84 plates (V)

    private:
        /** GZ34 dynamic resistance incl. HT winding: ~120 R at high current, more at low. */
        static double rectResistance (double current) noexcept
        {
            constexpr double rWinding = 60.0;
            constexpr double kPerv    = 0.0025;     // A / V^1.5 (fit to GZ34 data: 250 mA @ ~22 V drop)
            const double i = std::max (current, 1.0e-3);
            const double vDiode = std::cbrt ((i / kPerv) * (i / kPerv));   // V = (I/k)^(2/3)
            return rWinding + vDiode / i;
        }

        static constexpr double reservoirCap = 32e-6;

        double dt = 1.0 / 192000.0, iIdle = 0.2, vPeak = 360.0;
        double vb = vNominal, preampFactor = 1.0, preampCoeff = 0.0;
    };
}

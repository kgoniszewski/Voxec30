#pragma once

namespace vox::dsp
{
    //==============================================================================
    /** Passive, fully interactive Top Boost Treble/Bass network.

        The continuous-time transfer function is the exact 3rd-order solution of
        the passive "TMB" ladder (D. T. Yeh & J. O. Smith, "Discretization of the
        '59 Fender Bassman Tone Stack", DAFx-06), populated with AC30 Top Boost
        component values: 50 pF treble cap, 22 nF bass / slope caps, 1 MA treble
        and bass pots, 100 k slope resistor and the fixed 10 k "mid" resistor that
        Vox used instead of a Middle pot. This reproduces the strong, fixed mid
        scoop and the treble/bass interaction of the Top Boost circuit.

            H(s) = (b1 s + b2 s^2 + b3 s^3) / (1 + a1 s + a2 s^2 + a3 s^3)

        Discretised with the bilinear transform (we run at the oversampled rate,
        so frequency warping is negligible below 20 kHz) and processed in double
        precision TDF-II (3rd order with widely spread poles is precision sensitive).
        Coefficients are recomputed on the audio thread only when a control moved
        - it is a handful of multiplies, no allocation, no locks.
    */
    class TopBoostToneStack
    {
    public:
        void prepare (double sampleRate);
        void reset() noexcept;

        /** @param treble01, bass01  pot rotation in [0,1] (log taper applied inside) */
        void setControls (float treble01, float bass01) noexcept;

        float process (float x) noexcept
        {
            const double in = x;
            const double y  = b[0] * in + s[0];
            s[0] = b[1] * in - a[1] * y + s[1];
            s[1] = b[2] * in - a[2] * y + s[2];
            s[2] = b[3] * in - a[3] * y;
            return (float) y;
        }

    private:
        void updateCoefficients() noexcept;

        double fs = 48000.0;
        float treble = -1.0f, bass = -1.0f;
        double b[4] {}, a[4] {}, s[3] {};
    };
}

#include "TopBoostToneStack.h"
#include "DspUtils.h"

#include <algorithm>
#include <cmath>

namespace vox::dsp
{
    void TopBoostToneStack::prepare (double sampleRate)
    {
        fs = sampleRate;
        treble = bass = -1.0f;      // force recompute
        setControls (0.5f, 0.5f);
        reset();
    }

    void TopBoostToneStack::reset() noexcept
    {
        s[0] = s[1] = s[2] = 0.0;
    }

    void TopBoostToneStack::setControls (float treble01, float bass01) noexcept
    {
        treble01 = std::clamp (treble01, 0.0f, 1.0f);
        bass01   = std::clamp (bass01,   0.0f, 1.0f);

        if (std::abs (treble01 - treble) < 1.0e-4f && std::abs (bass01 - bass) < 1.0e-4f)
            return;

        treble = treble01;
        bass   = bass01;
        updateCoefficients();
    }

    void TopBoostToneStack::updateCoefficients() noexcept
    {
        // --- AC30 Top Boost component values --------------------------------
        constexpr double C1 = 50e-12;     // treble cap
        constexpr double C2 = 22e-9;      // bass cap
        constexpr double C3 = 22e-9;      // mid/slope cap
        constexpr double R1 = 1.0e6;      // treble pot
        constexpr double R2 = 1.0e6;      // bass pot
        constexpr double R3 = 10.0e3;     // fixed "mid" resistor (no Middle pot on an AC30)
        constexpr double R4 = 100.0e3;    // slope resistor

        // Pot positions: log taper; keep away from exact 0 to avoid a degenerate network.
        const double t = std::clamp ((double) audioTaper (treble), 0.001, 1.0);
        const double l = std::clamp ((double) audioTaper (bass),   0.001, 1.0);
        constexpr double m = 1.0;          // fixed resistor = "mid pot fully up"

        const double m2 = m * m;

        const double b1 = t * C1 * R1 + m * C3 * R3 + l * (C1 * R2 + C2 * R2) + (C1 * R3 + C2 * R3);

        const double b2 = t * (C1 * C2 * R1 * R4 + C1 * C3 * R1 * R4)
                        - m2 * (C1 * C3 * R3 * R3 + C2 * C3 * R3 * R3)
                        + m * (C1 * C3 * R1 * R3 + C1 * C3 * R3 * R3 + C2 * C3 * R3 * R3)
                        + l * (C1 * C2 * R1 * R2 + C1 * C2 * R2 * R4 + C1 * C3 * R2 * R4)
                        + l * m * (C1 * C3 * R2 * R3 + C2 * C3 * R2 * R3)
                        + (C1 * C2 * R1 * R3 + C1 * C2 * R3 * R4 + C1 * C3 * R3 * R4);

        const double b3 = l * m * (C1 * C2 * C3 * R1 * R2 * R3 + C1 * C2 * C3 * R2 * R3 * R4)
                        - m2 * (C1 * C2 * C3 * R1 * R3 * R3 + C1 * C2 * C3 * R3 * R3 * R4)
                        + m * (C1 * C2 * C3 * R1 * R3 * R3 + C1 * C2 * C3 * R3 * R3 * R4)
                        + t * C1 * C2 * C3 * R1 * R3 * R4
                        - t * m * C1 * C2 * C3 * R1 * R3 * R4
                        + t * l * C1 * C2 * C3 * R1 * R2 * R4;

        const double a0 = 1.0;

        const double a1 = (C1 * R1 + C1 * R3 + C2 * R3 + C2 * R4 + C3 * R4)
                        + m * C3 * R3 + l * (C1 * R2 + C2 * R2);

        const double a2 = m * (C1 * C3 * R1 * R3 - C2 * C3 * R3 * R4 + C1 * C3 * R3 * R3 + C2 * C3 * R3 * R3)
                        + l * m * (C1 * C3 * R2 * R3 + C2 * C3 * R2 * R3)
                        - m2 * (C1 * C3 * R3 * R3 + C2 * C3 * R3 * R3)
                        + l * (C1 * C2 * R2 * R4 + C1 * C2 * R1 * R2 + C1 * C3 * R2 * R4 + C2 * C3 * R2 * R4)
                        + (C1 * C2 * R1 * R4 + C1 * C3 * R1 * R4 + C1 * C2 * R3 * R4
                           + C1 * C2 * R1 * R3 + C1 * C3 * R3 * R4 + C2 * C3 * R3 * R4);

        const double a3 = l * m * (C1 * C2 * C3 * R1 * R2 * R3 + C1 * C2 * C3 * R2 * R3 * R4)
                        - m2 * (C1 * C2 * C3 * R1 * R3 * R3 + C1 * C2 * C3 * R3 * R3 * R4)
                        + m * (C1 * C2 * C3 * R3 * R3 * R4 + C1 * C2 * C3 * R1 * R3 * R3 - C1 * C2 * C3 * R1 * R3 * R4)
                        + l * C1 * C2 * C3 * R1 * R2 * R4
                        + C1 * C2 * C3 * R1 * R3 * R4;

        // --- bilinear transform, s = c (1 - z^-1) / (1 + z^-1) ----------------
        const double c  = 2.0 * fs;
        const double c2 = c * c, c3 = c2 * c;

        const double B0 =  b1 * c + b2 * c2 + b3 * c3;
        const double B1 =  b1 * c - b2 * c2 - 3.0 * b3 * c3;
        const double B2 = -b1 * c - b2 * c2 + 3.0 * b3 * c3;
        const double B3 = -b1 * c + b2 * c2 - b3 * c3;

        const double A0 =       a0 + a1 * c + a2 * c2 + a3 * c3;
        const double A1 = 3.0 * a0 + a1 * c - a2 * c2 - 3.0 * a3 * c3;
        const double A2 = 3.0 * a0 - a1 * c - a2 * c2 + 3.0 * a3 * c3;
        const double A3 =       a0 - a1 * c + a2 * c2 - a3 * c3;

        b[0] = B0 / A0; b[1] = B1 / A0; b[2] = B2 / A0; b[3] = B3 / A0;
        a[0] = 1.0;     a[1] = A1 / A0; a[2] = A2 / A0; a[3] = A3 / A0;
    }
}

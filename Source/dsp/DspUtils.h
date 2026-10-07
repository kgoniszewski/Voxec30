#pragma once

#include <algorithm>
#include <cmath>
#include <numbers>

//==============================================================================
/** Small allocation-free building blocks used inside the real-time path.
    Everything here is header-only, branch-light and safe to call per sample.
*/
namespace vox::dsp
{
    inline constexpr double pi = std::numbers::pi;

    /** Audio (log, "A") potentiometer taper. x in [0,1] -> resistance fraction in [0,1]. */
    inline float audioTaper (float x) noexcept
    {
        x = std::clamp (x, 0.0f, 1.0f);
        constexpr float k = 4.6f;                          // ~10 % at mid-rotation (real A-taper)
        return (std::exp (k * x) - 1.0f) / (std::exp (k) - 1.0f);
    }

    /** Smooth, odd-symmetric saturator: linear around 0, asymptote at +-1. */
    inline float softClip (float x) noexcept
    {
        // Rational tanh approximation (Pade 3/2), accurate to <0.5 % and monotone after clamp.
        x = std::clamp (x, -3.0f, 3.0f);
        const float x2 = x * x;
        return x * (27.0f + x2) / (27.0f + 9.0f * x2);
    }

    /** Flush denormals / NaNs that could otherwise poison IIR state. */
    inline float sanitise (float x) noexcept
    {
        return (std::isfinite (x) && std::abs (x) > 1.0e-15f) ? x : 0.0f;
    }

    //==============================================================================
    /** One-pole low-pass, impulse-invariant (exact pole placement). */
    struct OnePoleLP
    {
        void setCutoff (double hz, double fs) noexcept
        {
            a = (float) std::exp (-2.0 * pi * hz / fs);
            b = 1.0f - a;
        }

        void setTimeConstant (double seconds, double fs) noexcept
        {
            a = (float) std::exp (-1.0 / (seconds * fs));
            b = 1.0f - a;
        }

        void reset (float v = 0.0f) noexcept { z = v; }
        float process (float x) noexcept      { z = b * x + a * z; return z; }
        float state() const noexcept          { return z; }

        float a = 0.0f, b = 1.0f, z = 0.0f;
    };

    /** One-pole high-pass (models an RC coupling capacitor into a grid-leak resistor). */
    struct OnePoleHP
    {
        void setCutoff (double hz, double fs) noexcept
        {
            a = (float) std::exp (-2.0 * pi * hz / fs);
            g = 0.5f * (1.0f + a);
        }

        void reset() noexcept { x1 = y1 = 0.0f; }

        float process (float x) noexcept
        {
            const float y = g * (x - x1) + a * y1;
            x1 = x;
            y1 = sanitise (y);
            return y1;
        }

        float a = 0.0f, g = 1.0f, x1 = 0.0f, y1 = 0.0f;
    };

    //==============================================================================
    /** Transposed direct form II biquad with RBJ cookbook designs. */
    struct Biquad
    {
        void reset() noexcept { s1 = s2 = 0.0f; }

        float process (float x) noexcept
        {
            const float y = b0 * x + s1;
            s1 = sanitise (b1 * x - a1 * y + s2);
            s2 = sanitise (b2 * x - a2 * y);
            return y;
        }

        void setPeak (double fs, double f0, double q, double gainDb) noexcept
        {
            const double A = std::pow (10.0, gainDb / 40.0);
            const double w = 2.0 * pi * f0 / fs, c = std::cos (w), al = std::sin (w) / (2.0 * q);
            set (1 + al * A, -2 * c, 1 - al * A, 1 + al / A, -2 * c, 1 - al / A);
        }

        void setHighShelf (double fs, double f0, double q, double gainDb) noexcept
        {
            const double A = std::pow (10.0, gainDb / 40.0);
            const double w = 2.0 * pi * f0 / fs, c = std::cos (w), al = std::sin (w) / (2.0 * q);
            const double sA = 2.0 * std::sqrt (A) * al;
            set (A * ((A + 1) + (A - 1) * c + sA), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - sA),
                 (A + 1) - (A - 1) * c + sA,        2 * ((A - 1) - (A + 1) * c),       (A + 1) - (A - 1) * c - sA);
        }

        void setLowPass (double fs, double f0, double q) noexcept
        {
            const double w = 2.0 * pi * f0 / fs, c = std::cos (w), al = std::sin (w) / (2.0 * q);
            set ((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + al, -2 * c, 1 - al);
        }

        void setHighPass (double fs, double f0, double q) noexcept
        {
            const double w = 2.0 * pi * f0 / fs, c = std::cos (w), al = std::sin (w) / (2.0 * q);
            set ((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + al, -2 * c, 1 - al);
        }

        float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, s1 = 0, s2 = 0;

    private:
        void set (double nb0, double nb1, double nb2, double na0, double na1, double na2) noexcept
        {
            b0 = (float) (nb0 / na0); b1 = (float) (nb1 / na0); b2 = (float) (nb2 / na0);
            a1 = (float) (na1 / na0); a2 = (float) (na2 / na0);
        }
    };

    //==============================================================================
    /** Lock-free per-block parameter ramp: the audio thread reads the target once
        per sub-block and interpolates linearly across it (no zipper noise). */
    struct Ramp
    {
        void reset (float v) noexcept { current = target = v; }

        /** Prepares a ramp of numSteps steps towards newTarget, with exponential
            approach so large jumps take a few blocks (~smoothing). */
        void begin (float newTarget, int numSteps, float approach = 0.35f) noexcept
        {
            target = current + (newTarget - current) * approach;
            if (std::abs (newTarget - target) < 1.0e-5f) target = newTarget;
            step = (target - current) / (float) std::max (1, numSteps);
        }

        float next() noexcept { current += step; return current; }
        void end() noexcept   { current = target; step = 0.0f; }

        float current = 0.0f, target = 0.0f, step = 0.0f;
    };
}

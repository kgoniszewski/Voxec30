#include "PowerAmpEL84.h"
#include "DspUtils.h"

#include <algorithm>
#include <cmath>

namespace vox::dsp
{
    //==============================================================================
    double EL84Pentode::plateCurrent (double vgk, double vg2) const noexcept
    {
        if (vg2 <= 0.0)
            return 0.0;

        const double arg = kp * (1.0 / mu + vgk / vg2);
        const double sp  = arg > 30.0 ? arg : std::log1p (std::exp (arg));
        return std::pow ((vg2 / kp) * sp, ex) / kg1;
    }

    float EL84Pentode::plateCurrentFast (float vgk, float vg2) const noexcept
    {
        const float arg = (float) kp * ((float) (1.0 / mu) + vgk / vg2);
        const float sp  = arg > 20.0f ? arg : std::log1p (std::exp (arg));
        const float e1  = (vg2 / (float) kp) * sp;
        return e1 > 1.0e-9f ? std::pow (e1, (float) ex) / (float) kg1 : 0.0f;
    }

    //==============================================================================
    float PowerAmpEL84::GridInput::process (float x, float vkNow, float coeffLeak, float coeffGrid, float alpha) noexcept
    {
        const float vNode = x - cap;
        const float vgk   = vNode - vkNow;

        constexpr float knee = 8.0f;
        const float kv    = knee * vgk;
        const float softp = kv > 20.0f ? vgk : std::log1p (std::exp (kv)) / knee;
        const float drop  = (1.0f - alpha) * softp;

        cap = sanitise (cap + coeffLeak * vNode + coeffGrid * drop);
        return vNode - drop;                      // grid voltage to ground
    }

    //==============================================================================
    void PowerAmpEL84::prepare (double sampleRate)
    {
        const double vg2 = bPlusNominal * screenDrop;

        // Idle point: Vk = Rk * Ik_total(Vgk = -Vk), 4 valves, Ik = Ia (1 + screenRatio)
        double lo = 0.0, hi = 30.0;
        for (int i = 0; i < 80; ++i)
        {
            const double v = 0.5 * (lo + hi);
            const double h = v - rk * 4.0 * (1.0 + screenRatio) * tube.plateCurrent (-v, vg2);
            (h > 0.0 ? hi : lo) = v;
        }
        vkIdle = 0.5 * (lo + hi);

        const double iaIdle = tube.plateCurrent (-vkIdle, vg2);
        idleSupplyCurrent   = 4.0 * (1.0 + screenRatio) * iaIdle + preampDraw;

        const double dt   = 1.0 / sampleRate;
        cathodeCoeff = (float) (1.0 - std::exp (-dt / (rk * ck)));

        constexpr double cc = 47e-9, rLeak = 220e3, rStop = 10e3 + 40e3;   // + PI output impedance
        capLeak   = (float) (dt / (rLeak * cc));
        capGrid   = (float) (dt / (rStop * cc));
        gridAlpha = (float) (1.0e3 / (1.0e3 + rStop));

        reset();
    }

    void PowerAmpEL84::reset() noexcept
    {
        gridInA = {};
        gridInB = {};
        vk = (float) vkIdle;
        supplyCurrent = idleSupplyCurrent;
    }

    float PowerAmpEL84::process (float gridA, float gridB, float supplyFactor) noexcept
    {
        const float bPlus = (float) bPlusNominal * supplyFactor;
        const float vg2   = bPlus * (float) screenDrop;

        const float vgA = gridInA.process (gridA, vk, capLeak, capGrid, gridAlpha);
        const float vgB = gridInB.process (gridB, vk, capLeak, capGrid, gridAlpha);

        // Two valves in parallel per side.
        const float iA = 2.0f * tube.plateCurrentFast (vgA - vk, vg2);
        const float iB = 2.0f * tube.plateCurrentFast (vgB - vk, vg2);

        // Shared bypassed cathode -> dynamic bias shift.
        const float iK = (iA + iB) * (float) (1.0 + screenRatio);
        vk += cathodeCoeff * (iK * (float) rk - vk);

        // Output transformer primary: difference current into the reflected load,
        // swing limited by (sagging) B+ minus the pentode knee.
        const float swing     = std::max (bPlus - (float) vKnee, 10.0f);
        const float vPrimary  = (iA - iB) * (float) rLoad;
        const float vLimited  = swing * softClip (vPrimary / swing);

        supplyCurrent = (double) iK + preampDraw;

        return vLimited / (float) (bPlusNominal - vKnee);
    }
}

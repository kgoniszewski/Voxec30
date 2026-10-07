#include "TriodeModel.h"
#include "DspUtils.h"

#include <algorithm>
#include <cmath>

namespace vox::dsp
{
    //==============================================================================
    double KorenTriode::plateCurrent (double vgk, double vpk) const noexcept
    {
        if (vpk <= 0.0)
            return 0.0;

        const double arg = kp * (1.0 / mu + vgk / std::sqrt (kvb + vpk * vpk));
        // softplus with overflow protection
        const double sp = arg > 30.0 ? arg : std::log1p (std::exp (arg));
        const double e1 = (vpk / kp) * sp;

        return e1 > 0.0 ? 2.0 * std::pow (e1, ex) / kg1 : 0.0;
    }

    //==============================================================================
    double TriodeStage::solvePlateCurrent (double u, double rkInLoop) const noexcept
    {
        // Solve  g(Ip) = Ip - Ip_koren(u - Ip*Rk, B+ - Ip*(Rp + Rk)) = 0.
        // g is strictly increasing in Ip, g(0) <= 0 and g(Imax) > 0 -> bisection
        // is guaranteed to converge. This only runs in prepare().
        const double bPlus = config.supplyVolts;
        const double rTot  = config.plateResistor + rkInLoop;

        double lo = 0.0, hi = bPlus / rTot;

        for (int i = 0; i < 80; ++i)
        {
            const double ip = 0.5 * (lo + hi);
            const double g  = ip - config.tube.plateCurrent (u - ip * rkInLoop, bPlus - ip * rTot);
            (g > 0.0 ? hi : lo) = ip;
        }

        return 0.5 * (lo + hi);
    }

    void TriodeStage::prepare (const Config& cfg, double sampleRate)
    {
        config   = cfg;
        bypassed = cfg.cathodeCap > 0.0;

        const double rkLoop = bypassed ? 0.0 : cfg.cathodeResistor;

        // --- quiescent operating point -------------------------------------
        if (bypassed)
        {
            // Vk = Rk * Ip(Vgk = -Vk): bisection on h(Vk) = Vk - Rk * Ip(-Vk)
            double lo = 0.0, hi = 10.0;
            for (int i = 0; i < 80; ++i)
            {
                const double v = 0.5 * (lo + hi);
                const double h = v - cfg.cathodeResistor * solvePlateCurrent (-v, 0.0);
                (h > 0.0 ? hi : lo) = v;
            }
            vkQuiescent = 0.5 * (lo + hi);
            ipQuiescent = vkQuiescent / cfg.cathodeResistor;
        }
        else
        {
            ipQuiescent = solvePlateCurrent (0.0, rkLoop);
            vkQuiescent = ipQuiescent * cfg.cathodeResistor;
        }

        vpQuiescent = cfg.supplyVolts - ipQuiescent * cfg.plateResistor;

        // --- load-line lookup table ----------------------------------------
        table.resize ((size_t) tableSize);
        tableScale = (float) (tableSize - 1) / (uMax - uMin);

        for (int i = 0; i < tableSize; ++i)
        {
            const double u  = uMin + (double) i / tableScale;
            const double ip = solvePlateCurrent (u, rkLoop);
            table[(size_t) i] = { (float) (cfg.supplyVolts - ip * cfg.plateResistor), (float) ip };
        }

        const float u0 = bypassed ? (float) -vkQuiescent : 0.0f;
        smallSignalGain = (lookup (u0 + 0.01f).vp - lookup (u0 - 0.01f).vp) / 0.02;

        // --- dynamic coefficients (forward Euler, dt << all time constants) --
        const double dt = 1.0 / sampleRate;
        capCoeffLeak = cfg.couplingCap > 0.0 ? (float) (dt / (cfg.gridLeak * cfg.couplingCap)) : 0.0f;
        capCoeffGrid = cfg.couplingCap > 0.0 ? (float) (dt / (cfg.gridStopper * cfg.couplingCap)) : 0.0f;
        cathodeCoeff = bypassed ? (float) (1.0 - std::exp (-dt / (cfg.cathodeResistor * cfg.cathodeCap))) : 0.0f;
        gridAlpha    = (float) (cfg.gridCathodeOn / (cfg.gridCathodeOn + cfg.gridStopper));

        reset();
    }

    void TriodeStage::reset() noexcept
    {
        capCharge = 0.0f;
        vk = (float) vkQuiescent;
    }

    TriodeStage::Entry TriodeStage::lookup (float u) const noexcept
    {
        const float pos = std::clamp ((u - uMin) * tableScale, 0.0f, (float) tableSize - 1.001f);
        const auto  i   = (size_t) pos;
        const float f   = pos - (float) i;
        const auto& a   = table[i];
        const auto& b   = table[i + 1];
        return { a.vp + f * (b.vp - a.vp), a.ip + f * (b.ip - a.ip) };
    }

    float TriodeStage::process (float x, float supplyScale) noexcept
    {
        const float lambda = std::max (supplyScale, 0.5f);

        // Node between the coupling cap and the grid stopper.
        const float vNode = x - capCharge;

        // Grid conduction: smooth diode (softplus knee) in series with the grid stopper.
        const float vkNow   = bypassed ? vk : (float) vkQuiescent;
        const float vgkRaw  = vNode - vkNow;
        constexpr float knee = 12.0f;                               // 1/V, knee sharpness
        const float kv      = knee * vgkRaw;
        const float softp   = kv > 20.0f ? vgkRaw : std::log1p (std::exp (kv)) / knee;
        const float drop    = (1.0f - gridAlpha) * softp;           // voltage across stopper
        const float vGrid   = vNode - drop;

        // Static load-line nonlinearity with supply scaling.
        const float u = bypassed ? (vGrid - vk) : vGrid;
        const Entry e = lookup (u / lambda);
        const float vp = e.vp * lambda;
        const float ip = e.ip * (1.0f + 1.4f * (lambda - 1.0f));   // Ip ~ lambda^1.4 (linearised)

        // Slow states.
        if (bypassed)
            vk += cathodeCoeff * (ip * (float) config.cathodeResistor - vk);

        if (capCoeffLeak > 0.0f)
            capCharge = sanitise (capCharge + capCoeffLeak * vNode + capCoeffGrid * drop);

        return vp - (float) vpQuiescent * lambda;
    }
}

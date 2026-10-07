// Offline sanity test for the AC30 circuit model (desktop only, -DVOX_BUILD_TESTS=ON).
//
//  - renders a plucked-string-like test signal through several knob settings,
//  - checks for NaN/Inf, DC, runaway levels,
//  - measures the harmonic content of a 220 Hz sine (THD rises with Volume),
//  - measures real-time CPU factor,
//  - optionally writes a WAV for listening:  VoxAC30_OfflineTest out.wav

#include <juce_audio_formats/juce_audio_formats.h>
#include <juce_dsp/juce_dsp.h>

#include "dsp/AC30Circuit.h"

#include <chrono>
#include <cstdio>

namespace
{
    constexpr double fs = 48000.0;
    constexpr int block = 128;

    std::vector<float> makePluck (double seconds, float peak)
    {
        // Karplus-Strong E2 / A2 / D3 plucks: rich, decaying, guitar-like spectrum.
        std::vector<float> out ((size_t) (seconds * fs), 0.0f);
        juce::Random rng (42);
        const double notes[] = { 82.41, 110.0, 146.83, 196.0 };
        size_t pos = 0;

        for (double f : notes)
        {
            const int period = (int) (fs / f);
            std::vector<float> line ((size_t) period);
            for (auto& s : line) s = rng.nextFloat() * 2.0f - 1.0f;

            const size_t len = out.size() / 4;
            for (size_t i = 0; i < len && pos + i < out.size(); ++i)
            {
                auto& a = line[i % (size_t) period];
                const auto& b = line[(i + 1) % (size_t) period];
                const float v = a;
                a = 0.4985f * (a + b);
                out[pos + i] += v * peak;
            }
            pos += len;
        }
        return out;
    }

    struct Stats { float peak = 0, rms = 0, dc = 0; bool finite = true; };

    Stats render (vox::dsp::AC30Circuit& amp, std::vector<float>& buf)
    {
        for (size_t i = 0; i < buf.size(); i += block)
            amp.process (buf.data() + i, (int) std::min<size_t> (block, buf.size() - i));

        Stats s;
        double sum = 0, sq = 0;
        for (float v : buf)
        {
            s.finite &= std::isfinite (v);
            s.peak = std::max (s.peak, std::abs (v));
            sum += v; sq += (double) v * v;
        }
        s.dc  = (float) (sum / (double) buf.size());
        s.rms = (float) std::sqrt (sq / (double) buf.size());
        return s;
    }

    float thdOfSine (const vox::dsp::AC30Circuit::Controls& c, float amplitude)
    {
        vox::dsp::AC30Circuit amp;
        amp.setControls (c);
        amp.prepare (fs, block);

        const int n = 1 << 15;
        std::vector<float> x ((size_t) (n + 24000));
        for (size_t i = 0; i < x.size(); ++i)
            x[i] = amplitude * (float) std::sin (2.0 * juce::MathConstants<double>::pi * 187.5 * (double) i / fs);   // bin-exact

        render (amp, x);

        juce::dsp::FFT fft (15);
        std::vector<float> data ((size_t) n * 2, 0.0f);
        std::copy (x.end() - n, x.end(), data.begin());
        fft.performFrequencyOnlyForwardTransform (data.data());

        const int fundamental = (int) std::lround (187.5 * n / fs);
        double h1 = data[(size_t) fundamental], hs = 0;
        for (int k = 2; k <= 10; ++k)
            hs += (double) data[(size_t) (fundamental * k)] * data[(size_t) (fundamental * k)];
        return (float) (100.0 * std::sqrt (hs) / std::max (h1, 1e-9));
    }
}

int main (int argc, char** argv)
{
    int failures = 0;

    struct Case { const char* name; vox::dsp::AC30Circuit::Controls c; };
    const Case cases[] = {
        { "clean      ", { 2.5f, 5.0f, 5.0f, 2.0f, 6.0f } },
        { "edge       ", { 5.0f, 6.0f, 4.0f, 3.0f, 6.0f } },
        { "crunch     ", { 8.0f, 7.0f, 4.0f, 3.0f, 8.0f } },
        { "cranked    ", { 10.0f, 10.0f, 10.0f, 0.0f, 10.0f } },
        { "dark/cut   ", { 7.0f, 3.0f, 8.0f, 10.0f, 7.0f } },
        { "all zero   ", { 0.0f, 0.0f, 0.0f, 0.0f, 0.0f } },
    };

    std::printf ("%-12s %9s %9s %9s %8s\n", "setting", "peak", "rms dB", "dc", "THD%");

    for (const auto& tc : cases)
    {
        vox::dsp::AC30Circuit amp;
        amp.setControls (tc.c);
        amp.prepare (fs, block);

        auto sig = makePluck (4.0, 0.5f);
        const auto s = render (amp, sig);
        const float thd = thdOfSine (tc.c, 0.3f);

        std::printf ("%-12s %9.4f %9.2f %9.5f %8.2f\n", tc.name, s.peak,
                     juce::Decibels::gainToDecibels (s.rms, -120.0f), s.dc, thd);

        if (! s.finite || s.peak > 4.0f || std::abs (s.dc) > 0.01f)
        {
            std::printf ("   -> FAIL\n");
            ++failures;
        }
    }

    // --- abrupt knob sweeps must not blow up -------------------------------------------
    {
        vox::dsp::AC30Circuit amp;
        amp.prepare (fs, block);
        auto sig = makePluck (4.0, 0.8f);
        juce::Random rng (1);
        bool ok = true;
        for (size_t i = 0; i < sig.size(); i += block)
        {
            amp.setControls ({ rng.nextFloat() * 10, rng.nextFloat() * 10, rng.nextFloat() * 10,
                               rng.nextFloat() * 10, rng.nextFloat() * 10 });
            amp.process (sig.data() + i, (int) std::min<size_t> (block, sig.size() - i));
            for (size_t k = i; k < std::min (sig.size(), i + block); ++k)
                ok &= std::isfinite (sig[k]) && std::abs (sig[k]) < 4.0f;
        }
        std::printf ("random knob automation: %s\n", ok ? "ok" : "FAIL");
        failures += ok ? 0 : 1;
    }

    // --- CPU ------------------------------------------------------------------------------
    {
        vox::dsp::AC30Circuit amp;
        amp.setControls ({ 8.0f, 7.0f, 4.0f, 3.0f, 8.0f });
        amp.prepare (fs, block);
        auto sig = makePluck (20.0, 0.5f);
        const auto t0 = std::chrono::steady_clock::now();
        render (amp, sig);
        const double secs = std::chrono::duration<double> (std::chrono::steady_clock::now() - t0).count();
        std::printf ("CPU: %.2f%% of real time (single core, 4x oversampled amp, no cab)\n", 100.0 * secs / 20.0);
    }

    // --- optional WAV render ------------------------------------------------------------
    if (argc > 1)
    {
        vox::dsp::AC30Circuit amp;
        amp.setControls ({ 7.0f, 7.0f, 4.0f, 2.0f, 7.0f });
        amp.prepare (fs, block);
        auto sig = makePluck (4.0, 0.5f);
        render (amp, sig);

        juce::File f = juce::File::getCurrentWorkingDirectory().getChildFile (argv[1]);
        f.deleteFile();
        juce::WavAudioFormat wav;
        if (auto os = std::unique_ptr<juce::OutputStream> (f.createOutputStream()))
        {
            auto opts = juce::AudioFormatWriterOptions{}.withSampleRate (fs).withNumChannels (1).withBitsPerSample (24);
            if (auto w = wav.createWriterFor (os, opts))
            {
                const float* ch[] = { sig.data() };
                w->writeFromFloatArrays (ch, 1, (int) sig.size());
                std::printf ("wrote %s\n", f.getFullPathName().toRawUTF8());
            }
        }
    }

    std::printf (failures == 0 ? "ALL TESTS PASSED\n" : "%d TEST(S) FAILED\n", failures);
    return failures == 0 ? 0 : 1;
}

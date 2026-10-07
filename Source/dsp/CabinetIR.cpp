#include "CabinetIR.h"

#include <VoxBinaryData.h>

namespace vox::dsp
{
    CabinetIR::CabinetIR()
        : convolution (juce::dsp::Convolution::NonUniform { 256 })   // zero added latency
    {
    }

    void CabinetIR::prepare (const juce::dsp::ProcessSpec& spec)
    {
        convolution.prepare (spec);
    }

    void CabinetIR::reset() noexcept
    {
        convolution.reset();
    }

    void CabinetIR::process (float* samples, int numSamples) noexcept
    {
        if (! hasImpulse.load (std::memory_order_acquire))
            return;

        float* channels[] = { samples };
        juce::dsp::AudioBlock<float> block (channels, 1, (size_t) numSamples);
        convolution.process (juce::dsp::ProcessContextReplacing<float> (block));
    }

    bool CabinetIR::loadDefault()
    {
        int size = 0;
        const char* data = VoxBinaryData::getNamedResource ("AlnicoBlue_2x12_wav", size);

        if (data == nullptr || size <= 0)
        {
            jassertfalse;   // Resources/IR/AlnicoBlue_2x12.wav missing at configure time
            return false;
        }

        convolution.loadImpulseResponse (data, (size_t) size,
                                         juce::dsp::Convolution::Stereo::no,
                                         juce::dsp::Convolution::Trim::yes,
                                         0,  // keep the full IR
                                         juce::dsp::Convolution::Normalise::yes);

        currentName = "Alnico Blue 2x12 (built-in)";
        currentFile = juce::File();
        hasImpulse.store (true, std::memory_order_release);
        return true;
    }

    bool CabinetIR::loadFromFile (const juce::File& file)
    {
        if (! file.existsAsFile())
            return false;

        // Validate the file before handing it to the convolution engine.
        juce::AudioFormatManager formats;
        formats.registerBasicFormats();

        if (std::unique_ptr<juce::AudioFormatReader> reader { formats.createReaderFor (file) }; reader == nullptr
             || reader->lengthInSamples < 16)
            return false;

        convolution.loadImpulseResponse (file,
                                         juce::dsp::Convolution::Stereo::no,
                                         juce::dsp::Convolution::Trim::yes,
                                         0,
                                         juce::dsp::Convolution::Normalise::yes);

        currentName = file.getFileNameWithoutExtension();
        currentFile = file;
        hasImpulse.store (true, std::memory_order_release);
        return true;
    }

    juce::File CabinetIR::getUserIRDirectory()
    {
        auto dir = juce::File::getSpecialLocation (juce::File::userDocumentsDirectory)
                       .getChildFile ("VoxAC30 IR");
        dir.createDirectory();
        return dir;
    }
}

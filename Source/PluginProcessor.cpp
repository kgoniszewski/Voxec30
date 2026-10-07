#include "PluginProcessor.h"
#include "PluginEditor.h"

namespace
{
    const juce::Identifier irPathProperty { "irPath" };
}

//==============================================================================
VoxAC30Processor::VoxAC30Processor()
    : AudioProcessor (BusesProperties()
                          .withInput  ("Guitar", juce::AudioChannelSet::mono(), true)
                          .withOutput ("Output", juce::AudioChannelSet::mono(), true)),
      apvts (*this, nullptr, "VoxAC30", VoxParams::createLayout())
{
    pVolume = apvts.getRawParameterValue (VoxParams::volume);
    pTreble = apvts.getRawParameterValue (VoxParams::treble);
    pBass   = apvts.getRawParameterValue (VoxParams::bass);
    pCut    = apvts.getRawParameterValue (VoxParams::cut);
    pMaster = apvts.getRawParameterValue (VoxParams::master);
    pCabOn  = apvts.getRawParameterValue (VoxParams::cabOn);

    jassert (pVolume && pTreble && pBass && pCut && pMaster && pCabOn);

    loadDefaultCabinetIR();
}

//==============================================================================
bool VoxAC30Processor::isBusesLayoutSupported (const BusesLayout& layouts) const
{
    const auto in  = layouts.getMainInputChannelSet();
    const auto out = layouts.getMainOutputChannelSet();

    const bool inOk  = in  == juce::AudioChannelSet::mono() || in  == juce::AudioChannelSet::stereo();
    const bool outOk = out == juce::AudioChannelSet::mono() || out == juce::AudioChannelSet::stereo();
    return inOk && outOk;
}

void VoxAC30Processor::prepareToPlay (double sampleRate, int samplesPerBlock)
{
    amp.prepare (sampleRate, samplesPerBlock);
    cabinet.prepare ({ sampleRate, (juce::uint32) samplesPerBlock, 1 });
    dryCab.setSize (1, samplesPerBlock, false, true, false);

    cabMix = *pCabOn > 0.5f ? 1.0f : 0.0f;
    setLatencySamples (amp.getLatencySamples());
}

void VoxAC30Processor::releaseResources()
{
    cabinet.reset();
    amp.reset();
}

//==============================================================================
void VoxAC30Processor::processBlock (juce::AudioBuffer<float>& buffer, juce::MidiBuffer&)
{
    juce::ScopedNoDenormals noDenormals;

    const int numSamples = buffer.getNumSamples();
    const int numIn      = getTotalNumInputChannels();
    const int numOut     = getTotalNumOutputChannels();

    if (numSamples == 0 || numOut == 0)
        return;

    if (numIn == 0)
    {
        buffer.clear();
        return;
    }

    // Guitar = input 1 of the interface (AXE I/O One instrument input).
    float* mono = buffer.getWritePointer (0);

    inputPeak.store (std::max (inputPeak.load (std::memory_order_relaxed),
                               buffer.getMagnitude (0, 0, numSamples)),
                     std::memory_order_relaxed);

    // --- parameters (lock-free atomic reads) --------------------------------------
    amp.setControls ({ pVolume->load (std::memory_order_relaxed),
                       pTreble->load (std::memory_order_relaxed),
                       pBass  ->load (std::memory_order_relaxed),
                       pCut   ->load (std::memory_order_relaxed),
                       pMaster->load (std::memory_order_relaxed) });

    const float cabTarget = pCabOn->load (std::memory_order_relaxed) > 0.5f ? 1.0f : 0.0f;

    // --- amp + cabinet, in sub-blocks no larger than the prepared scratch buffer ----
    const int maxChunk = std::max (1, dryCab.getNumSamples());

    for (int start = 0; start < numSamples; start += maxChunk)
    {
        const int n = std::min (maxChunk, numSamples - start);
        float* x = mono + start;

        amp.process (x, n);

        float* dry = dryCab.getWritePointer (0);
        std::copy (x, x + n, dry);
        cabinet.process (x, n);   // always runs so the IR state stays warm while bypassed

        // De-zippered cab on/off (~20 ms)
        const float step = 1.0f / (0.02f * (float) getSampleRate());

        for (int i = 0; i < n; ++i)
        {
            cabMix += juce::jlimit (-step, step, cabTarget - cabMix);
            const float y = dry[i] + cabMix * (x[i] - dry[i]);
            x[i] = juce::jlimit (-1.0f, 1.0f, std::isfinite (y) ? y : 0.0f);   // ear / speaker protection
        }
    }

    outputPeak.store (std::max (outputPeak.load (std::memory_order_relaxed),
                                buffer.getMagnitude (0, 0, numSamples)),
                      std::memory_order_relaxed);

    // Mono -> every output channel (dual-mono when the output bus is stereo).
    for (int ch = 1; ch < numOut; ++ch)
        buffer.copyFrom (ch, 0, buffer, 0, 0, numSamples);

    for (int ch = numOut; ch < numIn; ++ch)
        buffer.clear (ch, 0, numSamples);
}

//==============================================================================
juce::AudioProcessorEditor* VoxAC30Processor::createEditor()
{
    return new VoxAC30Editor (*this);
}

//==============================================================================
bool VoxAC30Processor::loadCabinetIR (const juce::File& file)
{
    if (! cabinet.loadFromFile (file))
        return false;

    // On iOS the sandbox path changes between app updates, so IRs living in the
    // app's IR folder are stored by file name only.
    const auto irDir = vox::dsp::CabinetIR::getUserIRDirectory();
    apvts.state.setProperty (irPathProperty,
                             file.isAChildOf (irDir) ? file.getRelativePathFrom (irDir)
                                                     : file.getFullPathName(),
                             nullptr);
    return true;
}

void VoxAC30Processor::loadDefaultCabinetIR()
{
    cabinet.loadDefault();
    apvts.state.setProperty (irPathProperty, juce::String(), nullptr);
}

void VoxAC30Processor::getStateInformation (juce::MemoryBlock& destData)
{
    if (auto xml = apvts.copyState().createXml())
        copyXmlToBinary (*xml, destData);
}

void VoxAC30Processor::setStateInformation (const void* data, int sizeInBytes)
{
    if (auto xml = getXmlFromBinary (data, sizeInBytes))
    {
        if (! xml->hasTagName (apvts.state.getType()))
            return;

        apvts.replaceState (juce::ValueTree::fromXml (*xml));

        const auto irPath = apvts.state.getProperty (irPathProperty).toString();
        const auto irFile = irPath.isEmpty() ? juce::File()
                                             : vox::dsp::CabinetIR::getUserIRDirectory().getChildFile (irPath);

        if (irFile.existsAsFile() && loadCabinetIR (irFile))
            return;

        loadDefaultCabinetIR();
    }
}

//==============================================================================
juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter()
{
    return new VoxAC30Processor();
}

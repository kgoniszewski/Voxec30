#pragma once

#include <juce_audio_processors/juce_audio_processors.h>
#include <juce_dsp/juce_dsp.h>

#include "Parameters.h"
#include "dsp/AC30Circuit.h"
#include "dsp/CabinetIR.h"

#include <atomic>

//==============================================================================
/** Vox AC30 Top Boost - circuit-modelled guitar amplifier (standalone app).

    I/O: mono guitar in (AXE I/O One input 1) -> mono out. A stereo output
    layout is also accepted, in which case the mono signal is mirrored to both
    channels (handy for headphones on the interface).

    Real-time contract of processBlock():
      - parameters are read from APVTS std::atomic<float> pointers,
      - all buffers / tables / oversampling filters are allocated in prepareToPlay(),
      - the convolution engine receives new IRs through its own lock-free queue,
      - meters are published through std::atomic<float>.
    => no locks, no allocation, no system calls on the audio thread.
*/
class VoxAC30Processor final : public juce::AudioProcessor
{
public:
    VoxAC30Processor();
    ~VoxAC30Processor() override = default;

    //==============================================================================
    void prepareToPlay (double sampleRate, int samplesPerBlock) override;
    void releaseResources() override;
    bool isBusesLayoutSupported (const BusesLayout& layouts) const override;
    void processBlock (juce::AudioBuffer<float>&, juce::MidiBuffer&) override;
    using AudioProcessor::processBlock;

    //==============================================================================
    bool hasEditor() const override { return true; }

    const juce::String getName() const override { return JucePlugin_Name; }
    bool acceptsMidi() const override  { return false; }
    bool producesMidi() const override { return false; }
    bool isMidiEffect() const override { return false; }
    double getTailLengthSeconds() const override { return 0.1; }

    int getNumPrograms() override                               { return 1; }
    int getCurrentProgram() override                            { return 0; }
    void setCurrentProgram (int) override                       {}
    const juce::String getProgramName (int) override            { return "AC30 Top Boost"; }
    void changeProgramName (int, const juce::String&) override  {}

    void getStateInformation (juce::MemoryBlock& destData) override;
    void setStateInformation (const void* data, int sizeInBytes) override;

    //==============================================================================
    // Message-thread API used by the editor
    juce::AudioProcessorValueTreeState& getValueTreeState() noexcept { return apvts; }

    bool loadCabinetIR (const juce::File& file);
    void loadDefaultCabinetIR();
    juce::String getCabinetName() const { return cabinet.getCurrentName(); }

    float getInputPeak() noexcept   { return inputPeak.exchange (0.0f, std::memory_order_relaxed); }
    float getOutputPeak() noexcept  { return outputPeak.exchange (0.0f, std::memory_order_relaxed); }

private:
    juce::AudioProcessorEditor* createEditor() override;

    juce::AudioProcessorValueTreeState apvts;

    std::atomic<float>* pVolume = nullptr;
    std::atomic<float>* pTreble = nullptr;
    std::atomic<float>* pBass   = nullptr;
    std::atomic<float>* pCut    = nullptr;
    std::atomic<float>* pMaster = nullptr;
    std::atomic<float>* pCabOn  = nullptr;

    vox::dsp::AC30Circuit amp;
    vox::dsp::CabinetIR  cabinet;

    float cabMix = 1.0f;                 // smoothed cab on/off cross-fade
    juce::AudioBuffer<float> dryCab;     // pre-allocated scratch for the cross-fade

    std::atomic<float> inputPeak { 0.0f }, outputPeak { 0.0f };

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (VoxAC30Processor)
};

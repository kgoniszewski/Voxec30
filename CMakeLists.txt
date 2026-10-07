# ==============================================================================
#  VoxAC30 Top Boost - standalone amp simulator for iPad Pro (M-series)
#
#  Generating the Xcode project for iPadOS (see README.md for details):
#
#    cmake -S . -B build-ios -G Xcode \
#          -DCMAKE_SYSTEM_NAME=iOS \
#          -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0 \
#          -DCMAKE_XCODE_ATTRIBUTE_DEVELOPMENT_TEAM=<YOUR_TEAM_ID>
#
#    open build-ios/VoxAC30.xcodeproj
#
#  The same CMakeLists also builds a macOS / Linux standalone (handy for
#  development and offline DSP tests) when CMAKE_SYSTEM_NAME is not iOS.
# ==============================================================================

cmake_minimum_required(VERSION 3.25)

# ------------------------------------------------------------------------------
#  Platform defaults (must be set before project())
# ------------------------------------------------------------------------------
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    set(CMAKE_OSX_DEPLOYMENT_TARGET "27.0" CACHE STRING "Minimum iPadOS version")
    # Apple Silicon only: arm64 device build (M2 iPad Pro).
    set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "Target architectures")
    set(CMAKE_XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "2" CACHE STRING "iPad only")
elseif(APPLE)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "Minimum macOS version")
    set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "Target architectures")
endif()

project(VoxAC30 VERSION 1.0.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set_property(GLOBAL PROPERTY USE_FOLDERS ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(VOX_DSP_ALWAYS_O3   "Compile DSP sources with -O3 in every configuration (glitch-free Debug builds)" ON)
option(VOX_BUILD_TESTS     "Build the offline DSP render test (desktop only)" OFF)
set(VOX_JUCE_PATH "" CACHE PATH "Path to a local JUCE 9.0.3 checkout (empty = download with FetchContent)")

# ------------------------------------------------------------------------------
#  JUCE 9.0.3
# ------------------------------------------------------------------------------
if(VOX_JUCE_PATH)
    add_subdirectory(${VOX_JUCE_PATH} ${CMAKE_BINARY_DIR}/JUCE EXCLUDE_FROM_ALL)
else()
    include(FetchContent)
    FetchContent_Declare(JUCE
        GIT_REPOSITORY https://github.com/juce-framework/JUCE.git
        GIT_TAG        9.0.3
        GIT_SHALLOW    TRUE
        GIT_PROGRESS   TRUE)
    FetchContent_MakeAvailable(JUCE)
endif()

# ------------------------------------------------------------------------------
#  Binary resources (cabinet impulse responses)
#  Every .wav dropped into Resources/IR is embedded. The file named
#  "AlnicoBlue_2x12.wav" is used as the default cabinet.
# ------------------------------------------------------------------------------
file(GLOB VOX_IR_FILES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/Resources/IR/*.wav")

juce_add_binary_data(VoxAC30_BinaryData
    HEADER_NAME VoxBinaryData.h
    NAMESPACE   VoxBinaryData
    SOURCES     ${VOX_IR_FILES})

# ------------------------------------------------------------------------------
#  The application (JUCE "plugin" target built ONLY as Standalone)
# ------------------------------------------------------------------------------
juce_add_plugin(VoxAC30
    PRODUCT_NAME                  "VoxAC30"
    COMPANY_NAME                  "Voxec"
    BUNDLE_ID                     "com.voxec.ac30topboost"
    VERSION                       ${PROJECT_VERSION}
    FORMATS                       Standalone
    PLUGIN_MANUFACTURER_CODE      Voxc
    PLUGIN_CODE                   Ac30
    IS_SYNTH                      FALSE
    NEEDS_MIDI_INPUT              FALSE
    NEEDS_MIDI_OUTPUT             FALSE
    IS_MIDI_EFFECT                FALSE
    EDITOR_WANTS_KEYBOARD_FOCUS   FALSE
    # --- iPadOS specifics ---------------------------------------------------
    MICROPHONE_PERMISSION_ENABLED TRUE
    MICROPHONE_PERMISSION_TEXT    "VoxAC30 needs audio input access to process your guitar signal (e.g. from an IK Multimedia AXE I/O One)."
    BACKGROUND_AUDIO_ENABLED      TRUE
    FILE_SHARING_ENABLED          TRUE
    DOCUMENT_BROWSER_ENABLED      TRUE
    STATUS_BAR_HIDDEN             TRUE
    TARGETED_DEVICE_FAMILY        2
    IPAD_SCREEN_ORIENTATIONS      UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight
    IPHONE_SCREEN_ORIENTATIONS    UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight)

target_sources(VoxAC30 PRIVATE
    Source/PluginProcessor.cpp
    Source/PluginProcessor.h
    Source/PluginEditor.cpp
    Source/PluginEditor.h
    Source/Parameters.h
    Source/dsp/DspUtils.h
    Source/dsp/TriodeModel.cpp
    Source/dsp/TriodeModel.h
    Source/dsp/TopBoostToneStack.cpp
    Source/dsp/TopBoostToneStack.h
    Source/dsp/PowerSupplyGZ34.h
    Source/dsp/PowerAmpEL84.cpp
    Source/dsp/PowerAmpEL84.h
    Source/dsp/AC30Circuit.cpp
    Source/dsp/AC30Circuit.h
    Source/dsp/CabinetIR.cpp
    Source/dsp/CabinetIR.h
    Source/gui/VoxLookAndFeel.cpp
    Source/gui/VoxLookAndFeel.h)

target_include_directories(VoxAC30 PRIVATE Source)

target_compile_definitions(VoxAC30 PUBLIC
    JUCE_WEB_BROWSER=0
    JUCE_USE_CURL=0
    JUCE_VST3_CAN_REPLACE_VST2=0
    JUCE_USE_XINPUT=0)                      # Linux dev builds only, ignored on Apple

target_link_libraries(VoxAC30
    PRIVATE
        VoxAC30_BinaryData
        juce::juce_audio_utils
        juce::juce_audio_formats
        juce::juce_dsp
    PUBLIC
        juce::juce_recommended_config_flags
        juce::juce_recommended_lto_flags
        juce::juce_recommended_warning_flags)

# ------------------------------------------------------------------------------
#  Optimisation: aggressive -O3 for the real-time DSP translation units
# ------------------------------------------------------------------------------
set(VOX_DSP_SOURCES
    Source/PluginProcessor.cpp
    Source/dsp/TriodeModel.cpp
    Source/dsp/TopBoostToneStack.cpp
    Source/dsp/PowerAmpEL84.cpp
    Source/dsp/AC30Circuit.cpp
    Source/dsp/CabinetIR.cpp)

if(MSVC)
    set(VOX_DSP_FLAGS /O2 /fp:fast)
else()
    # No -ffast-math: we rely on std::isfinite() guards in the audio path.
    set(VOX_DSP_FLAGS -O3 -fno-math-errno -fno-trapping-math -ffp-contract=fast)
    if(APPLE AND CMAKE_OSX_ARCHITECTURES STREQUAL "arm64")
        list(APPEND VOX_DSP_FLAGS -mcpu=apple-m1)   # baseline for every M-series chip (incl. M2)
    endif()
endif()

if(VOX_DSP_ALWAYS_O3)
    set_source_files_properties(${VOX_DSP_SOURCES} PROPERTIES COMPILE_OPTIONS "${VOX_DSP_FLAGS}")
else()
    foreach(flag IN LISTS VOX_DSP_FLAGS)
        set_property(SOURCE ${VOX_DSP_SOURCES} APPEND PROPERTY COMPILE_OPTIONS "$<$<CONFIG:Release>:${flag}>")
    endforeach()
endif()

if(CMAKE_GENERATOR STREQUAL "Xcode")
    set_target_properties(VoxAC30 VoxAC30_Standalone PROPERTIES
        XCODE_ATTRIBUTE_GCC_OPTIMIZATION_LEVEL[variant=Release] "3"
        XCODE_ATTRIBUTE_LLVM_LTO[variant=Release] "YES_THIN"
        XCODE_ATTRIBUTE_DEAD_CODE_STRIPPING "YES"
        XCODE_ATTRIBUTE_CLANG_CXX_LANGUAGE_STANDARD "c++20")
    if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
        set_target_properties(VoxAC30_Standalone PROPERTIES
            XCODE_ATTRIBUTE_CODE_SIGN_STYLE "Automatic"
            XCODE_ATTRIBUTE_SUPPORTS_MACCATALYST "NO"
            XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS "iphoneos iphonesimulator")
    endif()
endif()

# ------------------------------------------------------------------------------
#  Offline DSP test (desktop only): renders a synthetic guitar signal through
#  the full amp model and checks for NaNs / clipping / CPU budget.
# ------------------------------------------------------------------------------
if(VOX_BUILD_TESTS AND NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    juce_add_console_app(VoxAC30_OfflineTest PRODUCT_NAME "VoxAC30_OfflineTest")

    target_sources(VoxAC30_OfflineTest PRIVATE
        Tests/OfflineRenderTest.cpp
        Source/dsp/TriodeModel.cpp
        Source/dsp/TopBoostToneStack.cpp
        Source/dsp/PowerAmpEL84.cpp
        Source/dsp/AC30Circuit.cpp)

    target_include_directories(VoxAC30_OfflineTest PRIVATE Source)
    target_compile_definitions(VoxAC30_OfflineTest PRIVATE JUCE_WEB_BROWSER=0 JUCE_USE_CURL=0)
    target_link_libraries(VoxAC30_OfflineTest
        PRIVATE juce::juce_dsp juce::juce_audio_formats
        PUBLIC  juce::juce_recommended_config_flags juce::juce_recommended_warning_flags)
endif()

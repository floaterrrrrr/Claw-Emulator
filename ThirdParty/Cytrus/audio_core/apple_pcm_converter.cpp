// SPDX-License-Identifier: GPL-3.0-or-later
#if defined(__APPLE__)
#include "audio_core/apple_pcm_converter.h"
#include "audio_core/pcm_conversion.h"
#include <AudioToolbox/AudioToolbox.h>
#include <algorithm>
#include <array>
#include <stdexcept>
#include <string>
#include <utility>

namespace AudioCore {
namespace {
// Temporary starvation must not be reported as end-of-stream: conversion
// resumes when the next DSP frame arrives, retaining the resampler's history.
constexpr OSStatus input_starved = 0x6b737472; // 'kstr'
AudioStreamBasicDescription PCMFormat(unsigned int rate) {
    AudioStreamBasicDescription format{};
    format.mSampleRate = rate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked |
                          kAudioFormatFlagsNativeEndian;
    format.mBytesPerPacket = 2 * sizeof(s16);
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = 2 * sizeof(s16);
    format.mChannelsPerFrame = 2;
    format.mBitsPerChannel = 16;
    return format;
}
void Require(OSStatus status, const char* operation) {
    if (status != noErr)
        throw std::runtime_error(std::string("Apple PCM converter could not ") + operation +
                                 " (status " + std::to_string(status) + ").");
}
}

struct ApplePCMConverter::Impl {
    AudioConverterRef converter = nullptr;
    Input input;
    std::array<s16, 1024 * 2> scratch{};
    explicit Impl(Input input_) : input(std::move(input_)) {}
    ~Impl() { if (converter) AudioConverterDispose(converter); }

    static OSStatus Supply(AudioConverterRef, UInt32* packets, AudioBufferList* data,
                           AudioStreamPacketDescription** descriptions, void* context) noexcept {
        auto& self = *static_cast<Impl*>(context);
        if (descriptions) *descriptions = nullptr; // PCM has fixed-size packets.
        std::size_t count = 0;
        try {
            const auto requested = std::min<std::size_t>(*packets, self.scratch.size() / 2);
            if (requested != 0) count = std::min(self.input(self.scratch.data(), requested), requested);
        } catch (...) {
            *packets = 0;
            return kAudioConverterErr_UnspecifiedError;
        }
        *packets = static_cast<UInt32>(count);
        data->mNumberBuffers = 1;
        data->mBuffers[0].mNumberChannels = 2;
        data->mBuffers[0].mDataByteSize = static_cast<UInt32>(count * 2 * sizeof(s16));
        data->mBuffers[0].mData = count ? self.scratch.data() : nullptr;
        return count ? noErr : input_starved;
    }
};

ApplePCMConverter::ApplePCMConverter(Input input, unsigned int input_rate)
    : impl(std::make_unique<Impl>(std::move(input))) {
    if (!impl->input || input_rate == 0) throw std::invalid_argument("Invalid PCM input.");
    const auto source = PCMFormat(input_rate);
    const auto destination = PCMFormat(mobile_output_sample_rate);
    Require(AudioConverterNew(&source, &destination, &impl->converter), "create conversion");
    // High-quality sample-rate conversion at a fixed ratio, without a tempo
    // estimator or SoundTouch. This API does not promise hardware acceleration.
    if (input_rate != mobile_output_sample_rate) {
        const UInt32 quality = kAudioConverterQuality_High;
        Require(AudioConverterSetProperty(impl->converter, kAudioConverterSampleRateConverterQuality,
                                          sizeof(quality), &quality), "set resampling quality");
    }
}
ApplePCMConverter::~ApplePCMConverter() = default;

std::size_t ApplePCMConverter::Convert(std::span<s16> stereo) {
    if (stereo.size() < 2) return 0;
    const auto capacity = std::min<std::size_t>(stereo.size() / 2, 8192);
    UInt32 packets = static_cast<UInt32>(capacity);
    AudioBufferList output{};
    output.mNumberBuffers = 1;
    output.mBuffers[0] = {2, static_cast<UInt32>(capacity * 2 * sizeof(s16)), stereo.data()};
    const auto status = AudioConverterFillComplexBuffer(impl->converter, Impl::Supply, impl.get(),
                                                       &packets, &output, nullptr);
    if (status != input_starved) Require(status, "convert samples");
    return std::min<std::size_t>({packets, capacity,
                                 output.mBuffers[0].mDataByteSize / (2 * sizeof(s16))});
}
void ApplePCMConverter::Reset() { Require(AudioConverterReset(impl->converter), "reset conversion"); }
} // namespace AudioCore
#endif

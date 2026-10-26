// Copyright © 2025 Jarrod Norwell. All rights reserved.
// CoreAudio RemoteIO playback for the iPhone frontend.
#include "audio_core/audio_types.h"
#include "audio_core/coreaudio_sink.h"
#include <cstring>
#include <algorithm>
#include <atomic>
#include <stdexcept>
#include <string>
#include <utility>
#include <chrono>
#include <pthread.h>
#include <pthread/qos.h>

namespace AudioCore {
namespace {
std::atomic<bool> playback_paused{true};
std::atomic<unsigned> playback_speed{1};
std::atomic<float> playback_gain{1.f};
static_assert(std::atomic<bool>::is_always_lock_free);
static_assert(std::atomic<float>::is_always_lock_free);
static_assert(std::atomic<unsigned>::is_always_lock_free);
}
void SetCoreAudioPaused(bool paused) noexcept {
    playback_paused.store(paused, std::memory_order_relaxed);
}
void SetCoreAudioSpeed(unsigned multiplier) noexcept {
    playback_speed.store(multiplier == 2 || multiplier == 4 ? multiplier : 1, std::memory_order_relaxed);
}
void SetCoreAudioVolume(float volume) noexcept {
    playback_gain.store(MobileVolumeGain(volume), std::memory_order_relaxed);
}

CoreAudioSink::CoreAudioSink([[maybe_unused]] std::string device_name) {
    AudioComponentDescription description{};
    description.componentType = kAudioUnitType_Output;
    description.componentSubType = kAudioUnitSubType_RemoteIO;
    description.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent component = AudioComponentFindNext(nullptr, &description);
    if (!component) throw std::runtime_error("CoreAudio RemoteIO is unavailable.");
    const auto require_success = [this](OSStatus status, const char* operation) {
        if (status == noErr) return;
        Dispose();
        throw std::runtime_error(std::string("CoreAudio could not ") + operation +
                                 " (status " + std::to_string(status) + ").");
    };
    require_success(AudioComponentInstanceNew(component, &audio_unit), "create the output unit");
    AudioStreamBasicDescription format{};
    format.mSampleRate = mobile_output_sample_rate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked |
                          kAudioFormatFlagsNativeEndian;
    format.mBytesPerPacket = 2 * sizeof(s16);
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = 2 * sizeof(s16);
    format.mChannelsPerFrame = 2;
    format.mBitsPerChannel = 16;
    require_success(AudioUnitSetProperty(audio_unit, kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Input, 0, &format, sizeof(format)), "configure PCM playback");
    const UInt32 maximum_frames = 8192;
    require_success(AudioUnitSetProperty(audio_unit, kAudioUnitProperty_MaximumFramesPerSlice,
        kAudioUnitScope_Global, 0, &maximum_frames, sizeof(maximum_frames)), "configure callback capacity");
    const AURenderCallbackStruct callback{NativeCallback, this};
    require_success(AudioUnitSetProperty(audio_unit, kAudioUnitProperty_SetRenderCallback,
        kAudioUnitScope_Input, 0, &callback, sizeof(callback)), "install the render callback");
    require_success(AudioUnitInitialize(audio_unit), "initialize playback");
    // Playback starts only after DspInterface has configured its sample rate and callback.
}

void CoreAudioSink::Dispose() noexcept {
    StopPlayback();
    if (!audio_unit) return;
    AudioUnitUninitialize(audio_unit);
    AudioComponentInstanceDispose(audio_unit);
    audio_unit = nullptr;
    started = false;
}

CoreAudioSink::~CoreAudioSink() { Dispose(); }

void CoreAudioSink::SetCallback(std::function<void(s16*, std::size_t)> callback) {
    if (!callback) { SetFrameCallback({}); return; }
    SetFrameCallback([callback = std::move(callback)](s16* buffer, std::size_t frames) {
        callback(buffer, frames);
        return frames;
    });
}

void CoreAudioSink::StopPlayback() noexcept {
    // AudioOutputUnitStop quiesces RemoteIO before producer-owned state is freed.
    if (started && audio_unit && AudioOutputUnitStop(audio_unit) != noErr) {
        // Failed stops must not leave a callback accessing reset/freed storage.
        AudioUnitUninitialize(audio_unit);
        AudioComponentInstanceDispose(audio_unit);
        audio_unit = nullptr;
    }
    started = false;
    producer_running.store(false, std::memory_order_release);
    producer_cv.notify_all();
    if (producer.joinable()) producer.join();
    converter.reset(); // Worker is joined before disposing its converter.
}

void CoreAudioSink::SetFrameCallback(FrameCallback callback) {
    if (!audio_unit) throw std::runtime_error("CoreAudio output is unavailable.");
    StopPlayback();
    if (!audio_unit) throw std::runtime_error("CoreAudio could not stop the previous output unit.");
    output.ResetStopped();
    volume.ResetStopped(playback_gain.load(std::memory_order_relaxed));
    callback_speed = playback_speed.load(std::memory_order_relaxed);
    cb = std::move(callback);
    if (!cb) return;
    converter = std::make_unique<ApplePCMConverter>(cb,
        native_sample_rate * std::min(callback_speed, 2u));
    producer_running.store(true, std::memory_order_release);
    const unsigned initial_speed = callback_speed;
    producer = std::thread([this, initial_speed] { Produce(initial_speed); });
    const auto status = AudioOutputUnitStart(audio_unit);
    if (status != noErr) {
        Dispose();
        throw std::runtime_error("CoreAudio could not start playback (status " +
                                 std::to_string(status) + ").");
    }
    started = true;
}

void CoreAudioSink::Produce(unsigned initial_speed) noexcept {
    pthread_setname_np("ClawAudioProducer");
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
    const auto wait = [this](std::chrono::milliseconds duration) {
        std::unique_lock lock{producer_mutex};
        producer_cv.wait_for(lock, duration, [this] {
            return !producer_running.load(std::memory_order_acquire);
        });
    };
    unsigned previous_speed = initial_speed;
    while (producer_running.load(std::memory_order_acquire)) {
        if (playback_paused.load(std::memory_order_relaxed)) {
            wait(std::chrono::milliseconds(25));
            continue;
        }
        // At 2x, play twice as fast with naturally higher pitch. A fixed input
        // rate per mode replaces wall-clock tempo estimation entirely.
        const unsigned multiplier = playback_speed.load(std::memory_order_relaxed);
        if (multiplier == 4) {
            // Drain decoded guest PCM without conversion/playback. This avoids
            // stale dialogue queues and spends no resampling work at 4x.
            previous_speed = 4;
            try {
                if (!cb(pcm_scratch.data(), mobile_producer_frames)) wait(std::chrono::milliseconds(5));
            } catch (...) { wait(std::chrono::milliseconds(10)); }
            continue;
        }
        if (multiplier != previous_speed) {
            try {
                converter = std::make_unique<ApplePCMConverter>(cb,
                    native_sample_rate * multiplier);
                previous_speed = multiplier;
            } catch (...) { wait(std::chrono::milliseconds(10)); continue; }
        }
        const auto buffered = output.BufferedFrames();
        if (buffered >= mobile_latency_frames) {
            wait(std::chrono::milliseconds(10));
            continue;
        }
        const auto requested = std::min(mobile_producer_frames, mobile_latency_frames - buffered);
        try {
            const auto written = converter->Convert({pcm_scratch.data(), requested * 2});
            if (written == 0) { wait(std::chrono::milliseconds(5)); continue; }
            if (multiplier == playback_speed.load(std::memory_order_relaxed))
                output.Push({pcm_scratch.data(), written * 2});
        } catch (...) {
            // A producer failure yields buffered audio, then a fade to silence.
            // Never propagate exceptions or perform DSP on RemoteIO's callback.
            wait(std::chrono::milliseconds(10));
        }
    }
}

OSStatus CoreAudioSink::NativeCallback(void* ref_con,
    [[maybe_unused]] AudioUnitRenderActionFlags* action_flags,
    [[maybe_unused]] const AudioTimeStamp* timestamp,
    [[maybe_unused]] UInt32 bus_number, UInt32 number_frames,
    AudioBufferList* data) noexcept {
    if (!ref_con || !data) return noErr;
    auto* sink = static_cast<CoreAudioSink*>(ref_con);
    for (UInt32 i = 0; i < data->mNumberBuffers; ++i) {
        auto& buffer = data->mBuffers[i];
        if (!buffer.mData) continue;
        std::memset(buffer.mData, 0, buffer.mDataByteSize);
    }
    if (playback_paused.load(std::memory_order_relaxed)) {
        sink->output.Mute();
        return noErr;
    }
    const unsigned multiplier = playback_speed.load(std::memory_order_relaxed);
    if (multiplier != sink->callback_speed) {
        sink->output.Discard();
        sink->callback_speed = multiplier;
    }
    if (multiplier == 4) return noErr; // output was zeroed, game-only mute
    if (data->mNumberBuffers != 1 || !data->mBuffers[0].mData ||
        data->mBuffers[0].mNumberChannels != 2) return noErr;
    auto& buffer = data->mBuffers[0];
    auto* output = static_cast<s16*>(buffer.mData);
    const auto frames = std::min<std::size_t>(number_frames,
        buffer.mDataByteSize / (2 * sizeof(s16)));
    // Only bounded copies/fades and lock-free index access happen on RemoteIO.
    sink->output.Read({output, frames * 2});
    sink->volume.Apply({output, frames * 2}, playback_gain.load(std::memory_order_relaxed));
    return noErr;
}

unsigned int CoreAudioSink::GetNativeSampleRate() const {
    // The producer's Apple converter resamples guest PCM to this client rate.
    return mobile_output_sample_rate;
}

std::vector<std::string> ListCoreAudioSinkDevices() { return {"auto"}; }
} // namespace AudioCore

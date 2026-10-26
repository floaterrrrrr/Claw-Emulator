//
//  coreaudio_sink.hpp
//  Cytrus
//
//  Created by Jarrod Norwell on 13/1/2025.
//  Copyright © 2025 Jarrod Norwell. All rights reserved.
//

#pragma once

#include <cstddef>
#include <array>
#include <functional>
#include <atomic>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <string>
#include <vector>
#include <AudioUnit/AudioUnit.h>

#include "audio_core/sink.h"
#include "audio_core/pcm_conversion.h"
#include "audio_core/mobile_audio_buffer.h"
#include "audio_core/apple_pcm_converter.h"
#include "audio_core/mobile_audio_volume.h"

namespace AudioCore {
// One emulator session owns the RemoteIO sink. This never locks the audio thread.
void SetCoreAudioPaused(bool paused) noexcept;
void SetCoreAudioSpeed(unsigned multiplier) noexcept;
void SetCoreAudioVolume(float volume) noexcept;
class CoreAudioSink final : public Sink {
public:
    explicit CoreAudioSink(std::string device_id);
    ~CoreAudioSink() override;

    unsigned int GetNativeSampleRate() const override;

    void SetCallback(std::function<void(s16*, std::size_t)> cb) override;
    // Returns only real produced frames, so starvation cannot enqueue fake DC audio.
    using FrameCallback = ApplePCMConverter::Input;
    void SetFrameCallback(FrameCallback callback);

private:
    AudioUnit audio_unit = nullptr;
    bool started = false;
    unsigned callback_speed = 1; // Owned solely by RemoteIO while running.
    FrameCallback cb;
    MobilePCM16Buffer output;
    MobileAudioVolume volume;
    std::unique_ptr<ApplePCMConverter> converter;
    std::array<s16, mobile_producer_frames * 2> pcm_scratch{};
    std::thread producer;
    std::atomic<bool> producer_running{false};
    std::mutex producer_mutex;
    std::condition_variable producer_cv;
    void Produce(unsigned initial_speed) noexcept;
    void StopPlayback() noexcept;
    void Dispose() noexcept;

    static OSStatus NativeCallback(void* ref_con, AudioUnitRenderActionFlags* action_flags,
                                   const AudioTimeStamp* timestamp, UInt32 bus_number,
                                   UInt32 number_frames, AudioBufferList* data) noexcept;
};

std::vector<std::string> ListCoreAudioSinkDevices();
} // namespace AudioCore

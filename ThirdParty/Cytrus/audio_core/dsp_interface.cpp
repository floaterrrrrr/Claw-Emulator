// Copyright 2017-2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the license.txt file included.

#include <cstddef>
#include "audio_core/dsp_interface.h"
#include "audio_core/sink.h"
#include "audio_core/sink_details.h"
#include "common/assert.h"
#include "common/settings.h"
#include "core/core.h"
#include "core/dumping/backend.h"
#if defined(HAVE_COREAUDIO) && HAVE_COREAUDIO
#include "audio_core/coreaudio_sink.h"
#endif

namespace AudioCore {

DspInterface::DspInterface(Core::System& system_) : system(system_) {}

DspInterface::~DspInterface() = default;

void DspInterface::SetSink(AudioCore::SinkType sink_type, std::string_view audio_device) {
    // Dispose of the current sink first to avoid contention.
    sink.reset();

    sink = AudioCore::GetSinkDetails(sink_type).create_sink(audio_device);
    output_sample_rate = sink->GetNativeSampleRate();
#if !defined(HAVE_COREAUDIO) || !HAVE_COREAUDIO
    time_stretcher.SetOutputSampleRate(output_sample_rate);
#endif
    last_production = std::chrono::steady_clock::now();
#if defined(HAVE_COREAUDIO) && HAVE_COREAUDIO
    if (sink_type == AudioCore::SinkType::CoreAudio) {
        static_cast<CoreAudioSink&>(*sink).SetFrameCallback(
            [this](s16* buffer, std::size_t frames) {
                return ReadNativePCM(buffer, frames);
            });
        return;
    }
#endif
    sink->SetCallback(
        [this](s16* buffer, std::size_t num_frames) { OutputCallback(buffer, num_frames); });
}

Sink& DspInterface::GetSink() {
    ASSERT(sink);
    return *sink.get();
}

void DspInterface::EnableStretching(bool enable) {
#if defined(HAVE_COREAUDIO) && HAVE_COREAUDIO
    // ApplePCMConverter owns iOS resampling. Never enable SoundTouch here.
    enable_time_stretching = false;
    (void)enable;
#else
    enable_time_stretching = enable;
#endif
}

void DspInterface::OutputFrame(StereoFrame16 frame) {
    if (!sink) {
        return;
    }

    if (sink->ImmediateSubmission()) {
        sink->PushSamples(frame.data(), frame.size());
    } else {
        fifo.Push(frame.data(), frame.size());
    }

    auto video_dumper = system.GetVideoDumper();
    if (video_dumper && video_dumper->IsDumping()) {
        video_dumper->AddAudioFrame(std::move(frame));
    }
}

void DspInterface::OutputSample(std::array<s16, 2> sample) {
    if (!sink) {
        return;
    }

    if (sink->ImmediateSubmission()) {
        sink->PushSamples(&sample, 1);
    } else {
        fifo.Push(&sample, 1);
    }

    auto video_dumper = system.GetVideoDumper();
    if (video_dumper && video_dumper->IsDumping()) {
        video_dumper->AddAudioSample(std::move(sample));
    }
}

std::size_t DspInterface::ReadNativePCM(s16* buffer, std::size_t num_frames) {
    const auto written = fifo.Pop(buffer, num_frames);
    const float volume = std::clamp(Settings::Volume(), 0.0f, 1.0f);
    if (volume != 1.0f) {
        const float gain = volume * volume * volume;
        for (std::size_t i = 0; i < written * 2; ++i)
            buffer[i] = static_cast<s16>(buffer[i] * gain);
    }
    return written;
}

std::size_t DspInterface::OutputCallback(s16* buffer, std::size_t num_frames, bool buffered,
                                        std::size_t queued_frames) {
#if defined(HAVE_COREAUDIO) && HAVE_COREAUDIO
    (void)queued_frames;
    const auto written = ReadNativePCM(buffer, num_frames);
    if (!buffered) std::fill(buffer + written * 2, buffer + num_frames * 2, 0);
    return written;
#else
    if (num_frames == 0) return 0;
    // Never read System/perf_stats from RemoteIO: shutdown destroys that state
    // before the sink. A different client rate also always needs resampling.
    const bool should_stretch = enable_time_stretching.load() ||
                                output_sample_rate != native_sample_rate;
    if (performing_time_stretching && !should_stretch) {
        // If we just stopped stretching, flush the stretcher before returning to normal output.
        flushing_time_stretcher = true;
    }
    performing_time_stretching = should_stretch;

    std::size_t frames_written = 0;
    if (performing_time_stretching) {
        const auto num_in = fifo.Pop(input_scratch.data(), fifo.Capacity());
        if (buffered) {
            const auto now = std::chrono::steady_clock::now();
            const double elapsed = std::chrono::duration<double>(now - last_production).count();
            last_production = now;
            frames_written = time_stretcher.ProcessBuffered(input_scratch.data(), num_in, buffer,
                                                            num_frames, queued_frames, elapsed);
        } else {
            frames_written = time_stretcher.Process(input_scratch.data(), num_in, buffer, num_frames);
        }
    } else {
        if (flushing_time_stretcher) {
            time_stretcher.Flush();
            frames_written = time_stretcher.Process(nullptr, 0, buffer, num_frames);
            flushing_time_stretcher = false;

            // Make sure any frames that did not fit are cleared from the time stretcher,
            // so that they do not bleed into the next time the stretcher is enabled.
            time_stretcher.Clear();
        }
        frames_written += fifo.Pop(buffer + frames_written * 2, num_frames - frames_written);
    }

    if (frames_written > 0) {
        std::memcpy(&last_frame[0], buffer + 2 * (frames_written - 1), 2 * sizeof(s16));
    }

    // Hold last emitted frame; this prevents popping.
    for (std::size_t i = frames_written; !buffered && i < num_frames; i++) {
        std::memcpy(buffer + 2 * i, &last_frame[0], 2 * sizeof(s16));
    }

    // Implementation of the hardware volume slider
    // A cubic curve is used to approximate a linear change in human-perceived loudness
    const float linear_volume = std::clamp(Settings::Volume(), 0.0f, 1.0f);
    if (linear_volume != 1.0) {
        const float volume_scale_factor = linear_volume * linear_volume * linear_volume;
        for (std::size_t i = 0; i < (buffered ? frames_written : num_frames); i++) {
            buffer[i * 2 + 0] = static_cast<s16>(buffer[i * 2 + 0] * volume_scale_factor);
            buffer[i * 2 + 1] = static_cast<s16>(buffer[i * 2 + 1] * volume_scale_factor);
        }
    }
    return frames_written;
#endif
}

} // namespace AudioCore

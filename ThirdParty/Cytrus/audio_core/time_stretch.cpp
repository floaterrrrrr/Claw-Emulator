// Copyright 2016 Citra Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the license.txt file included.

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <memory>
#include <type_traits>
#include <SoundTouch.h>

#include "audio_core/audio_types.h"
#include "audio_core/pcm_conversion.h"
#include "audio_core/mobile_audio_buffer.h"
#include "audio_core/time_stretch.h"
#include "common/assert.h"
#include "common/logging/log.h"

namespace AudioCore {

TimeStretcher::TimeStretcher() : sound_touch(std::make_unique<soundtouch::SoundTouch>()) {
    sound_touch->setChannels(2);
    sound_touch->setSampleRate(native_sample_rate);
    sound_touch->setPitch(1.0);
    sound_touch->setTempo(1.0);
}

TimeStretcher::~TimeStretcher() = default;

void TimeStretcher::SetOutputSampleRate(unsigned int sample_rate) {
    if (sample_rate == 0) return;
    output_sample_rate = sample_rate;
    // Sample-rate conversion changes rate; stretching changes tempo separately
    // so a 32728 Hz guest stream has the correct pitch at 48000 Hz output.
    sound_touch->setRate(static_cast<double>(native_sample_rate) / output_sample_rate);
    sound_touch->setSampleRate(sample_rate);
}

std::size_t TimeStretcher::Process(const s16* in, std::size_t num_in, s16* out,
                                   std::size_t num_out) {
    if (num_out == 0) return 0;
    // A shader/IO stall with an empty queue must not drive the tempo toward 5%.
    if (num_in == 0 && sound_touch->numSamples() == 0) return 0;
    const double time_delta = static_cast<double>(num_out) / output_sample_rate;
    double current_ratio = static_cast<double>(num_in) * output_sample_rate /
                           (static_cast<double>(num_out) * native_sample_rate);

    const double max_latency = 0.25; // seconds
    const double max_backlog = output_sample_rate * max_latency;
    const double backlog_fullness = sound_touch->numSamples() / max_backlog;
    if (backlog_fullness > 4.0) {
        // Too many samples in backlog: Don't push anymore on
        num_in = 0;
    }

    // We ideally want the backlog to be about 50% full.
    // This gives some headroom both ways to prevent underflow and overflow.
    // We tweak current_ratio to encourage this.
    constexpr double tweak_time_scale = 0.050; // seconds
    const double tweak_correction = (backlog_fullness - 0.5) * (time_delta / tweak_time_scale);
    current_ratio *= std::pow(std::max(0.01, 1.0 + 2.0 * tweak_correction),
                              tweak_correction < 0 ? 3.0 : 1.0);

    // This low-pass filter smoothes out variance in the calculated stretch ratio.
    // The time-scale determines how responsive this filter is.
    constexpr double lpf_time_scale = 0.712; // seconds
    const double lpf_gain = 1.0 - std::exp(-time_delta / lpf_time_scale);
    stretch_ratio += lpf_gain * (current_ratio - stretch_ratio);

    // Place a lower limit of 5% speed. When a game boots up, there will be
    // many silence samples. These do not need to be timestretched.
    stretch_ratio = std::max(stretch_ratio, 0.05);
    sound_touch->setTempo(stretch_ratio);

    LOG_TRACE(Audio, "{:5}/{:5} ratio:{:0.6f} backlog:{:0.6f}", num_in, num_out, stretch_ratio,
              backlog_fullness);

    return FeedAndReceive(in, num_in, out, num_out);
}

std::size_t TimeStretcher::ProcessBuffered(const s16* in, std::size_t num_in, s16* out,
                                          std::size_t num_out, std::size_t queued_frames,
                                          double elapsed_seconds) {
    if (num_out == 0) return 0;
    if (elapsed_seconds > 0.1 || elapsed_seconds < 0 || !std::isfinite(elapsed_seconds)) {
        // A deliberate pause is not an emulation slowdown.
        rate_sample_seconds = 0;
        rate_sample_frames = 0;
        elapsed_seconds = 0;
    }
    rate_sample_frames += num_in;
    rate_sample_seconds += elapsed_seconds;
    if (rate_sample_seconds >= 0.05) {
        if (rate_sample_frames != 0) {
            const double produced_ratio = std::clamp(
                rate_sample_frames / (native_sample_rate * rate_sample_seconds), 0.25, 3.0);
            const double fullness = static_cast<double>(queued_frames + sound_touch->numSamples()) /
                                    mobile_latency_frames;
            const double correction = std::clamp(fullness - 1.0, -1.0, 1.0) * 0.08;
            const double desired = produced_ratio * (1.0 + correction);
            const double gain = 1.0 - std::exp(-rate_sample_seconds / 0.712);
            stretch_ratio += gain * (desired - stretch_ratio);
            sound_touch->setTempo(std::clamp(stretch_ratio, 0.25, 3.0));
        }
        rate_sample_frames = 0;
        rate_sample_seconds = 0;
    }
    if (num_in == 0 && sound_touch->numSamples() == 0) return 0;
    // Bound exceptional backlog without allocating an unbounded audio history.
    if (sound_touch->numSamples() > output_sample_rate) num_in = 0;
    return FeedAndReceive(in, num_in, out, num_out);
}

std::size_t TimeStretcher::FeedAndReceive(const s16* in, std::size_t num_in, s16* out,
                                         std::size_t num_out) {
    if constexpr (std::is_floating_point<soundtouch::SAMPLETYPE>()) {
        for (std::size_t offset = 0; offset < num_in;) {
            const auto count = std::min(conversion_frames, num_in - offset);
            PCM16ToFloat({in + offset * 2, count * 2}, {float_input.data(), count * 2});
            sound_touch->putSamples(
                reinterpret_cast<const soundtouch::SAMPLETYPE*>(float_input.data()),
                static_cast<u32>(count));
            offset += count;
        }
        std::size_t samples_received = 0;
        while (samples_received < num_out) {
            const auto count = std::min(conversion_frames, num_out - samples_received);
            const auto received = sound_touch->receiveSamples(
                reinterpret_cast<soundtouch::SAMPLETYPE*>(float_output.data()), static_cast<u32>(count));
            if (received == 0) break;
            for (std::size_t i = 0; i < received * 2; ++i)
                out[samples_received * 2 + i] = FloatToPCM16(float_output[i]);
            samples_received += received;
        }
        return samples_received;
    } else if (std::is_same<soundtouch::SAMPLETYPE, s16>()) {
        // Use reinterpret_cast to workaround compile error when SAMPLETYPE is float.
        if (num_in != 0)
            sound_touch->putSamples(reinterpret_cast<const soundtouch::SAMPLETYPE*>(in),
                                    static_cast<u32>(num_in));
        return sound_touch->receiveSamples(reinterpret_cast<soundtouch::SAMPLETYPE*>(out),
                                           static_cast<u32>(num_out));
    } else {
        static_assert(std::is_floating_point<soundtouch::SAMPLETYPE>() ||
                      std::is_same<soundtouch::SAMPLETYPE, s16>());
        UNREACHABLE_MSG("Invalid SAMPLETYPE {}", typeid(soundtouch::SAMPLETYPE).name());
        return 0;
    }
}

void TimeStretcher::Clear() {
    sound_touch->clear();
    stretch_ratio = 1.0;
    rate_sample_frames = 0;
    rate_sample_seconds = 0;
    sound_touch->setTempo(1.0);
}

void TimeStretcher::Flush() {
    sound_touch->flush();
}

} // namespace AudioCore

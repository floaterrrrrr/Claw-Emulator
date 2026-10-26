// Copyright 2016 Citra Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the license.txt file included.

#pragma once

#include <array>
#include <cstddef>
#include <memory>
#include "audio_core/audio_types.h"
#include "common/common_types.h"

namespace soundtouch {
class SoundTouch;
}

namespace AudioCore {

class TimeStretcher {
public:
    TimeStretcher();
    ~TimeStretcher();

    void SetOutputSampleRate(unsigned int sample_rate);

    /// @param in       Input sample buffer
    /// @param num_in   Number of input frames in `in`
    /// @param out      Output sample buffer
    /// @param num_out  Desired number of output frames in `out`
    /// @returns Actual number of frames written to `out`
    std::size_t Process(const s16* in, std::size_t num_in, s16* out, std::size_t num_out);
    // Buffered production can run in bursts. Estimate speed from elapsed wall
    // time, not the size of an arbitrarily requested output chunk.
    std::size_t ProcessBuffered(const s16* in, std::size_t num_in, s16* out, std::size_t num_out,
                                std::size_t queued_frames, double elapsed_seconds);

    void Clear();

    void Flush();

private:
    std::size_t FeedAndReceive(const s16* in, std::size_t num_in, s16* out, std::size_t num_out);
    static constexpr std::size_t conversion_frames = 8192;
    std::unique_ptr<soundtouch::SoundTouch> sound_touch;
    // Sized before RemoteIO starts; conversion does not allocate per callback.
    std::array<float, conversion_frames * 2> float_input{};
    std::array<float, conversion_frames * 2> float_output{};
    unsigned int output_sample_rate = native_sample_rate;
    double stretch_ratio = 1.0;
    std::size_t rate_sample_frames = 0;
    double rate_sample_seconds = 0;
};

} // namespace AudioCore

// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <algorithm>
#include <cmath>
#include <span>
#include "common/common_types.h"

namespace AudioCore {
inline constexpr unsigned int mobile_output_sample_rate = 48000;
inline constexpr std::size_t mobile_callback_frames = 2048;

inline void PCM16ToFloat(std::span<const s16> input, std::span<float> output) noexcept {
    const auto count = std::min(input.size(), output.size());
    for (std::size_t i = 0; i < count; ++i) output[i] = static_cast<float>(input[i]) / 32768.0f;
}

inline s16 FloatToPCM16(float sample) noexcept {
    if (!std::isfinite(sample)) return 0;
    return static_cast<s16>(std::clamp(sample, -1.0f, 32767.0f / 32768.0f) * 32768.0f);
}
}

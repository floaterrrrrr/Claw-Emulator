// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <algorithm>
#include <atomic>
#include <cmath>

namespace Claw {

inline constexpr bool DefaultThreeDSAnisotropy = true;
// Selected before a new 3DS renderer starts. Samplers remain immutable for the
// session; changing the Settings toggle takes effect on the next game launch.
inline std::atomic_bool three_ds_anisotropy_enabled{DefaultThreeDSAnisotropy};

inline float ThreeDSAnisotropy(bool enabled, bool supported, bool linear_min,
                               bool linear_mag, float device_limit) {
    // Preserve nearest-filtered pixel art and framebuffer overlays. Some
    // drivers force linear filtering whenever anisotropy is enabled.
    if (!enabled || !supported || !linear_min || !linear_mag ||
        !std::isfinite(device_limit) || device_limit <= 1.0f) {
        return 1.0f;
    }
    return std::min(16.0f, device_limit);
}

} // namespace Claw

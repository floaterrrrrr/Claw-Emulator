// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <span>

namespace AudioCore {
inline float MobileVolumeGain(float volume) noexcept {
    if (!std::isfinite(volume)) return 0.f;
    volume = std::clamp(volume, 0.f, 1.f);
    return volume * volume * volume;
}

// Owned by RemoteIO only. A 5 ms ramp avoids clicks when the UI changes gain.
// The producer, converter and queue retain their sample rates and timing.
class MobileAudioVolume {
public:
    void ResetStopped(float gain) noexcept { current = target = gain; remaining = 0; }
    void Apply(std::span<std::int16_t> stereo, float gain) noexcept {
        if (gain != target) {
            target = gain;
            remaining = 240;
            step = (target - current) / remaining;
        }
        if (!remaining && current == 1.f) return;
        for (std::size_t i = 0; i + 1 < stereo.size(); i += 2) {
            if (remaining) {
                current += step;
                if (--remaining == 0) current = target;
            }
            stereo[i] = static_cast<std::int16_t>(stereo[i] * current);
            stereo[i + 1] = static_cast<std::int16_t>(stereo[i + 1] * current);
        }
    }
private:
    float current{1.f}, target{1.f}, step{};
    unsigned remaining{};
};
} // namespace AudioCore

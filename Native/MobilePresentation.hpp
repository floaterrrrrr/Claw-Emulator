// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <algorithm>
#include <chrono>
#include <initializer_list>
#include <span>

namespace Claw {
// Owned by the emulation worker. At 4x, publish the latest screen contents at
// most 60 times/second; never discard guest CPU/DSP ticks or rendered GPU work.
// This is presentation decimation, not a new worker or a display refresh change.
class FastForwardPresentation {
public:
    using Clock = std::chrono::steady_clock;
    bool Due(Clock::time_point now, bool force = false, unsigned maximum_fps = 60) noexcept {
        if (initialized && !force && now < next) return false;
        initialized = true;
        maximum_fps = std::clamp(maximum_fps, 1u, 120u);
        next = now + std::chrono::nanoseconds((1'000'000'000ULL + maximum_fps - 1) / maximum_fps);
        return true;
    }
    void Reset() noexcept { initialized = false; }
private:
    bool initialized = false;
    Clock::time_point next{};
};

// Only request modes advertised by this surface. FIFO is Vulkan's required
// fallback; iOS does not expose a portable way to override its display clock.
template <typename Mode>
Mode MobilePresentationMode(std::span<const Mode> supported, Mode mailbox, Mode immediate, Mode fifo) {
    for (const auto requested : {mailbox, immediate})
        if (std::find(supported.begin(), supported.end(), requested) != supported.end()) return requested;
    return fifo;
}
} // namespace Claw

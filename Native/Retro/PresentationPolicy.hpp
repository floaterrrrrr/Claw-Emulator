// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <mutex>

namespace ClawRetro {
// mGBA starts with a 21.3 ms reservoir at 48 kHz. Its callback can increase the
// budget for a larger hardware slice or repeated post-prime underruns.
// Other cores retain their existing stability reservoir.
constexpr std::size_t AudioTargetFrames(int core, std::size_t original) noexcept {
    return core == 1 ? 1024 : original;
}

// Callback-owned: adjusting the queue target never changes clock or pitch.
class AudioLatencyBudget {
public:
    std::size_t target(std::size_t slice) const noexcept {
        return std::min<std::size_t>(16384, std::max<std::size_t>(1024, slice * 2) + extra);
    }
    void observe(std::size_t slice, bool underrun) noexcept {
        if (underrun) { extra = std::min<std::size_t>(extra + 256, 2048); stableFrames = 0; }
        else if ((stableFrames += slice) >= 48000 * 30) {
            extra = extra >= 256 ? extra - 256 : 0;
            stableFrames = 0;
        }
    }
private:
    std::size_t extra{}, stableFrames{};
};

constexpr int DisplayTargetHz(bool paused, int thermal) noexcept {
    return paused || thermal >= 3 ? 30 : 60;
}

class PresentationStatistics {
public:
    struct Sample { double fps{}, worstIntervalMS{}; std::uint64_t frames{}; };
    void record(double time, unsigned epoch) {
        if (!std::isfinite(time) || time <= 0) return;
        std::lock_guard lock(mutex);
        if (!started || epoch != previousEpoch) {
            started = true; previousEpoch = epoch; last = windowStart = time;
            windowFrames = 0; value = {}; value.frames = 1;
            return;
        }
        if (time <= last) return; // Defensive against out-of-order callbacks.
        value.worstIntervalMS = std::max(value.worstIntervalMS, (time - last) * 1000);
        ++value.frames; ++windowFrames; last = time;
        if (time - windowStart >= 1) {
            value.fps = windowFrames / (time - windowStart);
            windowStart = time; windowFrames = 0;
        }
    }
    Sample sample(double now = 0) const {
        std::lock_guard lock(mutex);
        auto result = value;
        if (result.fps == 0 && last > windowStart) result.fps = windowFrames / (last - windowStart);
        if (now > last + 0.25) result.fps = 0; // HUD must not hide a stalled display.
        return result;
    }
private:
    mutable std::mutex mutex;
    Sample value;
    bool started = false;
    unsigned previousEpoch{};
    std::uint64_t windowFrames{};
    double last{}, windowStart{};
};
}

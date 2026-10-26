// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <chrono>

namespace Common {
// Explicit fast-forward selections override a guest temporary speed request.
// Normal playback retains the existing effective-limit rules.
constexpr double MobileFrameLimit(double selected_percent, double effective_percent) noexcept {
    return selected_percent == 200.0 || selected_percent == 400.0 ? selected_percent : effective_percent;
}

// Absolute monotonic deadlines follow guest VBlank timing, including 2x mode.
// Slow frames/pause/state restoration rebase instead of creating catch-up bursts.
class FramePacer {
public:
    using Clock = std::chrono::steady_clock;
    Clock::time_point Deadline(std::chrono::microseconds guest, Clock::time_point now,
                              unsigned int speed_percent) noexcept {
        if (!initialized || speed_percent == 0 || speed_percent != previous_speed ||
            guest <= previous_guest || guest - previous_guest > std::chrono::milliseconds(250)) {
            previous_guest = guest;
            previous_speed = speed_percent;
            deadline = now;
            initialized = speed_percent != 0;
            return now;
        }
        const auto interval = std::chrono::duration_cast<Clock::duration>(
            std::chrono::duration<double>(guest - previous_guest) * (100.0 / speed_percent));
        previous_guest = guest;
        deadline += interval;
        if (now > deadline + interval * 2) deadline = now;
        return deadline;
    }
private:
    bool initialized = false;
    unsigned int previous_speed = 0;
    std::chrono::microseconds previous_guest{0};
    Clock::time_point deadline{};
};
} // namespace Common

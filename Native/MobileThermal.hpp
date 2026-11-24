// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <optional>

namespace Claw {
// The UI publishes observations only. The running core's owner publishes the
// applied state at a boundary, never from NotificationCenter or GPU completion.
inline std::atomic<int> mobile_requested_thermal_state{0};
inline std::atomic<int> mobile_applied_thermal_state{0};
inline std::atomic<int> mobile_base_presentation_scale{2};

inline void ResetMobileThermal() noexcept {
    mobile_requested_thermal_state.store(0);
    mobile_applied_thermal_state.store(0);
}
inline bool MobileThermallyLimited() noexcept {
    return mobile_applied_thermal_state.load(std::memory_order_relaxed) >= 2;
}
constexpr int PresentationTargetScale(int output, int metalfx_input, bool bottom_only,
                                      bool can_scale) noexcept {
    if (!can_scale) return output;
    if (bottom_only) return std::min(output, 2);
    return metalfx_input > 0 ? std::min(output, metalfx_input) : output;
}

constexpr int ThermalPresentationScale(int target, int output, bool can_scale, int state) noexcept {
    if (!can_scale || state < 2) return target;
    const int limit = state >= 3 || output <= 2 ? 1 : 2;
    return std::min(target, limit);
}
constexpr int ThermalPresentationFPS(int state) noexcept { return state >= 3 ? 30 : 60; }
constexpr uint64_t ThermalTransitionBudget(uint64_t preferred, int state) noexcept {
    return state >= 3 ? 0 : state == 2 ? std::min<uint64_t>(preferred, 8 * 1024 * 1024) : preferred;
}

class MobileThermalGovernor {
public:
    using Clock = std::chrono::steady_clock;
    // All calls belong to one core/render worker. Time is injected in tests.
    int Observe(int reported, Clock::time_point now, bool enabled = true) noexcept {
        if (!enabled) {
            applied = 0;
            cooling_since.reset();
            return applied;
        }
        const int target = reported >= 3 ? 3 : reported == 2 ? 2 : 0;
        if (target >= applied) {
            applied = target;
            cooling_since.reset();
        } else {
            if (!cooling_since || cooling_target != target) {
                cooling_since = now;
                cooling_target = target;
            }
            if (now - *cooling_since >= std::chrono::seconds(30)) {
                applied = target;
                cooling_since.reset();
            }
        }
        return applied;
    }
private:
    int applied = 0, cooling_target = 0;
    std::optional<Clock::time_point> cooling_since;
};
} // namespace Claw

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
constexpr int ThermalRenderScale(int preferred_internal, int preferred_output, int state) noexcept {
    if (state >= 3) return 1;
    if (state == 2) return preferred_output > 2 ? 2 : 1;
    return std::clamp(preferred_internal, 1, 4);
}
constexpr int ThermalPresentationFPS(int state) noexcept { return state >= 3 ? 30 : 60; }
constexpr uint64_t ThermalTransitionBudget(uint64_t preferred, int state) noexcept {
    return state >= 3 ? 0 : state == 2 ? std::min<uint64_t>(preferred, 8 * 1024 * 1024) : preferred;
}

class MobileThermalGovernor {
public:
    using Clock = std::chrono::steady_clock;
    // All calls belong to one core/render worker. Time is injected in tests.
    int Observe(int reported, Clock::time_point now) noexcept {
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

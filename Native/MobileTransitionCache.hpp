// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <algorithm>
#include <array>
#include <atomic>
#include <cstdint>
#include "MobileDeviceProfile.hpp"

namespace Claw {
inline std::atomic<bool> transition_cache_enabled{true};
inline void ResetTransitionCache() noexcept { transition_cache_enabled.store(true); }
inline void ReleaseTransitionCache() noexcept { transition_cache_enabled.store(false); }

// Select recently retired, completed framebuffer surfaces without heap storage.
// Live/in-flight images are outside this additional idle-memory budget.
template <typename Id>
class TransitionRetention {
public:
    static constexpr unsigned max_slots = 8;
    static constexpr uint64_t max_bytes = 32 * 1024 * 1024;
    static constexpr uint64_t max_surface_bytes = 16 * 1024 * 1024;
    explicit TransitionRetention(MobileMemoryProfile profile = GetMobileMemoryProfile())
        : limits{profile} {}
    // Called once by TickFrame's garbage collector. Track idle *frames*, not
    // Vulkan submission ticks; in-flight resources always remain fence-protected.
    void BeginFrame() noexcept {
        previous = entries;
        previous_count = count;
        count = 0;
        retained_bytes = 0;
    }
    bool Keep(Id id, uint64_t bytes, uint64_t last_use, uint64_t completed) {
        const auto budget = ThermalTransitionBudget(limits.cache_bytes,
            mobile_applied_thermal_state.load(std::memory_order_relaxed));
        if (!transition_cache_enabled.load(std::memory_order_relaxed) ||
            completed <= last_use || !bytes || bytes > limits.max_surface_bytes ||
            count >= std::min(max_slots, limits.retained_surfaces) ||
            retained_bytes > budget || bytes > budget - retained_bytes)
            return false;
        unsigned idle_frames = 0;
        for (unsigned i = 0; limits.max_idle_frames && i < previous_count; ++i) {
            if (previous[i].id == id && previous[i].last_use == last_use) {
                idle_frames = previous[i].idle_frames + 1;
                break;
            }
        }
        if (limits.max_idle_frames && idle_frames >= limits.max_idle_frames) return false;
        entries[count++] = {id, last_use, idle_frames};
        retained_bytes += bytes;
        return true;
    }
    bool Full() const {
        return count >= std::min(max_slots, limits.retained_surfaces) ||
               retained_bytes >= ThermalTransitionBudget(limits.cache_bytes,
                   mobile_applied_thermal_state.load(std::memory_order_relaxed));
    }
    bool Contains(Id id) const {
        return std::any_of(entries.begin(), entries.begin() + count,
                           [id](const Entry& entry) { return entry.id == id; });
    }
private:
    struct Entry { Id id{}; uint64_t last_use{}; unsigned idle_frames{}; };
    const MobileMemoryProfile limits;
    std::array<Entry, max_slots> entries{}, previous{};
    unsigned previous_count{};
    unsigned count{};
    uint64_t retained_bytes{};
};
} // namespace Claw

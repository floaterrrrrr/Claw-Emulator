// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <algorithm>
#include <atomic>
#include <cstdint>
#include <string_view>
#include <charconv>
#include "MobileThermal.hpp"

namespace Claw {
inline constexpr uint64_t MiB = 1024 * 1024;
struct MobileDeviceCapabilities {
    bool apple8_or_newer{};
    uint64_t physical_memory_bytes{};
    uint64_t max_buffer_bytes{};
    unsigned iphone_generation{};
    bool metalfx_supported{};
    bool simulator{};
};
struct MobileGraphicsProfile {
    int resolution{2};
    int metalfx_input{};
    int cpu_clock{100}; // Guest timing, never host CPU utilisation.
};

constexpr MobileGraphicsProfile SelectMobileGraphicsProfile(MobileDeviceCapabilities caps) noexcept {
    // A12/A13 and low-memory phones start at native resolution. Model numbers
    // identify a baseline, not a promise about a particular game's frame rate.
    if (caps.simulator || (caps.iphone_generation && caps.iphone_generation <= 12) ||
        (caps.physical_memory_bytes && caps.physical_memory_bytes <= 3 * 1024 * MiB))
        return {1, 0, 100};
    // Keep the automatic profile at native 2x even on recent phones. The old
    // 2x -> 4x MetalFX default quadrupled both presentation buffers and added
    // a scaling pass on every presented frame. Users can still select it in
    // manual graphics settings when they prefer sharper output to headroom.
    return {2, 0, 100};
}
struct MobileMemoryProfile {
    bool legacy_gpu{};
    uint64_t cache_bytes{32 * MiB};
    unsigned retained_surfaces{8};
    unsigned max_idle_frames{}; // Zero preserves the existing modern-device policy.
    uint64_t max_surface_bytes{16 * MiB};
    uint64_t upload_buffer_bytes{512 * MiB};
};

constexpr MobileMemoryProfile SelectMobileMemoryProfile(MobileDeviceCapabilities caps) noexcept {
    const bool limited_memory = caps.physical_memory_bytes &&
                                caps.physical_memory_bytes <= 4 * 1024 * MiB;
    MobileMemoryProfile profile;
    const bool known_legacy_phone = caps.iphone_generation && caps.iphone_generation <= 14;
    if (!caps.apple8_or_newer || limited_memory || known_legacy_phone) {
        profile = {true, 12 * MiB, 4, 4, 12 * MiB, 128 * MiB};
    }
    if (profile.legacy_gpu && caps.physical_memory_bytes && caps.physical_memory_bytes <= 3 * 1024 * MiB) {
        profile.cache_bytes = 8 * MiB;
        profile.max_surface_bytes = 8 * MiB;
    }
    if (caps.max_buffer_bytes) {
        profile.upload_buffer_bytes = std::min(profile.upload_buffer_bytes, caps.max_buffer_bytes);
    }
    return profile;
}

// Configuration happens only after Claw3DSStop has joined the previous session,
// before creating any Vulkan or emulation workers. Readers never take a lock.
inline std::atomic<bool> legacy_mobile_gpu{false};
inline unsigned IPhoneGeneration(std::string_view machine) noexcept {
    if (!machine.starts_with("iPhone")) return 0;
    machine.remove_prefix(6);
    unsigned value = 0;
    const auto result = std::from_chars(machine.data(), machine.data() + machine.size(), value);
    return result.ec == std::errc{} && result.ptr < machine.data() + machine.size() && *result.ptr == ',' ? value : 0;
}
inline std::atomic<uint64_t> mobile_transition_cache_bytes{32 * MiB};
inline std::atomic<uint64_t> mobile_upload_buffer_bytes{512 * MiB};
inline MobileMemoryProfile ConfigureMobileMemoryProfile(MobileDeviceCapabilities caps) noexcept {
    const auto profile = SelectMobileMemoryProfile(caps);
    mobile_transition_cache_bytes.store(profile.cache_bytes, std::memory_order_relaxed);
    mobile_upload_buffer_bytes.store(profile.upload_buffer_bytes, std::memory_order_relaxed);
    legacy_mobile_gpu.store(profile.legacy_gpu, std::memory_order_release);
    return profile;
}
inline MobileMemoryProfile GetMobileMemoryProfile() noexcept {
    const bool legacy = legacy_mobile_gpu.load(std::memory_order_acquire);
    auto profile = SelectMobileMemoryProfile({!legacy, 0, 0});
    profile.cache_bytes = mobile_transition_cache_bytes.load(std::memory_order_relaxed);
    profile.max_surface_bytes = std::min(profile.max_surface_bytes, profile.cache_bytes);
    profile.upload_buffer_bytes = mobile_upload_buffer_bytes.load(std::memory_order_relaxed);
    return profile;
}
void InitializeMobileDeviceProfile(const char* data_directory);
// Hardware discovery is cached once. Settings, startup and diagnostics all use
// the same policy; no model probing or file I/O runs in a per-frame callback.
const MobileDeviceCapabilities& GetMobileDeviceCapabilities();
const char* MobileDeviceModel();
} // namespace Claw

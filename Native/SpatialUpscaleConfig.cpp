// SPDX-License-Identifier: GPL-3.0-or-later
#include "SpatialUpscaleConfig.hpp"
#include "MobileThermal.hpp"
#include <mutex>

namespace Claw {
namespace {
std::shared_ptr<SpatialUpscaleConfig> current;
std::mutex current_mutex;
}
void ConfigureSpatialUpscale(int input_scale) {
    auto next = input_scale == 2 || input_scale == 3
                    ? std::make_shared<SpatialUpscaleConfig>(2) : nullptr;
    std::lock_guard lock{current_mutex};
    current = std::move(next);
}
void SpatialUpscaleConfig::Fail(std::string reason) {
    std::lock_guard lock{failure_mutex};
    if (failed.load()) return;
    failure_reason = std::move(reason);
    failed.store(true);
}
std::string SpatialUpscaleConfig::FailureReason() const {
    std::lock_guard lock{failure_mutex};
    return failure_reason;
}
std::string SpatialUpscaleFailureReason() {
    const auto config = GetSpatialUpscaleConfig();
    return config ? config->FailureReason() : std::string{};
}
std::shared_ptr<SpatialUpscaleConfig> GetSpatialUpscaleConfig() {
    std::lock_guard lock{current_mutex};
    return current;
}
int SpatialUpscaleInputScale() {
    if (MobileThermallyLimited()) return 0;
    const auto config = GetSpatialUpscaleConfig();
    return config && !config->failed.load() ? config->input_scale : 0;
}
int SpatialUpscaleStatus() {
    if (MobileThermallyLimited()) return 0; // Temporarily bypassed, not failed.
    const auto config = GetSpatialUpscaleConfig();
    if (!config) return 0;
    if (config->failed.load()) return -1;
    return config->encoded.load() ? 1 : 2;
}
} // namespace Claw

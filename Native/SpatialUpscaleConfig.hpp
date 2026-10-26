// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <atomic>
#include <memory>
#include <mutex>
#include <string>

namespace Claw {
struct SpatialUpscaleConfig {
    explicit SpatialUpscaleConfig(int scale) : input_scale{scale} {}
    const int input_scale;
    std::atomic<bool> failed{false};
    std::atomic<bool> encoded{false};
    void Fail(std::string reason);
    std::string FailureReason() const;
private:
    mutable std::mutex failure_mutex;
    std::string failure_reason;
};
// Each session owns a separate token: an old GPU callback cannot alter a new game.
void ConfigureSpatialUpscale(int input_scale);
std::shared_ptr<SpatialUpscaleConfig> GetSpatialUpscaleConfig();
int SpatialUpscaleInputScale();
// 0 off, 2 ready, 1 encoding, -1 unavailable (native 4x fallback).
int SpatialUpscaleStatus();
std::string SpatialUpscaleFailureReason();
} // namespace Claw

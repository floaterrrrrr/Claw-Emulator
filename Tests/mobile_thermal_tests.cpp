// SPDX-License-Identifier: GPL-3.0-or-later
#include "MobileThermal.hpp"
#include "MobileTransitionCache.hpp"
#include "MobilePresentation.hpp"
#include "SpatialUpscaleConfig.hpp"
#include <cassert>
#include <iostream>
using namespace std::chrono_literals;
int main() {
    using namespace Claw;
    const auto now = MobileThermalGovernor::Clock::now();
    MobileThermalGovernor governor;
    assert(governor.Observe(0, now) == 0);
    assert(governor.Observe(1, now + 1s) == 0);
    assert(governor.Observe(2, now + 2s) == 2);
    assert(governor.Observe(0, now + 3s) == 2);
    assert(governor.Observe(2, now + 25s) == 2); // Heat resets cooling.
    assert(governor.Observe(1, now + 30s) == 2);
    assert(governor.Observe(0, now + 59s) == 2);
    assert(governor.Observe(0, now + 60s) == 0);
    assert(governor.Observe(3, now + 61s) == 3);
    assert(governor.Observe(2, now + 62s) == 3);
    assert(governor.Observe(2, now + 92s) == 2);
    assert(governor.Observe(0, now + 93s) == 2);
    assert(governor.Observe(0, now + 123s) == 0);
    assert(ThermalRenderScale(2, 4, 0) == 2); // Existing MetalFX 2x -> 4x.
    assert(ThermalRenderScale(2, 4, 1) == 2);
    assert(ThermalRenderScale(2, 4, 2) == 2); // Now native 2x, no MetalFX.
    assert(ThermalRenderScale(4, 4, 2) == 2);
    assert(ThermalRenderScale(2, 2, 2) == 1);
    assert(ThermalRenderScale(3, 3, 2) == 2);
    assert(ThermalRenderScale(1, 1, 2) == 1);
    for (int input : {1, 2, 3, 4}) assert(ThermalRenderScale(input, 4, 3) == 1);
    assert(ThermalPresentationFPS(0) == 60 && ThermalPresentationFPS(3) == 30);
    ConfigureSpatialUpscale(2);
    const auto session = GetSpatialUpscaleConfig();
    assert(SpatialUpscaleInputScale() == 2);
    mobile_applied_thermal_state.store(2);
    assert(SpatialUpscaleInputScale() == 0 && SpatialUpscaleStatus() == 0);
    assert(GetSpatialUpscaleConfig() == session && !session->failed.load());
    mobile_applied_thermal_state.store(0);
    assert(SpatialUpscaleInputScale() == 2); // Same session resumes, not rebuilt.
    ConfigureMobileMemoryProfile({false, 3ULL * 1024 * MiB, 128 * MiB, 11});
    assert(GetMobileMemoryProfile().cache_bytes == 8 * MiB);
    ResetTransitionCache();
    TransitionRetention<unsigned> cache;
    cache.BeginFrame();
    assert(cache.Keep(1, 8 * MiB, 1, 2));
    assert(!cache.Keep(2, 1, 1, 2));
    mobile_applied_thermal_state.store(3);
    cache.BeginFrame(); assert(!cache.Keep(1, MiB, 1, 2) && cache.Full());
    mobile_applied_thermal_state.store(0);
    cache.BeginFrame(); assert(cache.Keep(1, MiB, 1, 2));
    FastForwardPresentation gate;
    assert(gate.Due(now, false, 30));
    assert(!gate.Due(now + 20ms, false, 30));
    assert(gate.Due(now + 34ms, false, 30));
    assert(gate.Due(now + 35ms, true, 30)); // Save screenshots still bypass.
    ResetMobileThermal(); ConfigureSpatialUpscale(0);
    std::cout << "PASS: thermal curve, 30s cooling hysteresis, session-preserving MetalFX bypass/recovery, legacy 8MiB cache and 30Hz presentation gate\n";
}

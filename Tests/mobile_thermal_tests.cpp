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
    assert(governor.Observe(3, now + 124s) == 3);
    assert(governor.Observe(1, now + 125s) == 3);
    assert(governor.Observe(3, now + 129s, false) == 0);
    assert(governor.Observe(3, now + 130s, false) == 0);
    assert(governor.Observe(2, now + 131s) == 2);
    assert(governor.Observe(1, now + 132s) == 2);
    assert(governor.Observe(0, now + 161s) == 2);
    assert(governor.Observe(0, now + 162s) == 0);

    assert(PresentationTargetScale(4, 2, false, true) == 2);
    assert(PresentationTargetScale(4, 0, false, true) == 4);
    assert(PresentationTargetScale(4, 0, true, true) == 2);
    assert(PresentationTargetScale(1, 0, true, true) == 1);
    assert(PresentationTargetScale(4, 0, true, false) == 4);
    assert(ThermalPresentationScale(2, 4, true, 0) == 2);
    assert(ThermalPresentationScale(2, 4, true, 1) == 2);
    assert(ThermalPresentationScale(2, 4, true, 2) == 2);
    assert(ThermalPresentationScale(4, 4, true, 2) == 2);
    assert(ThermalPresentationScale(2, 2, true, 2) == 1);
    assert(ThermalPresentationScale(3, 3, true, 2) == 2);
    assert(ThermalPresentationScale(4, 4, false, 3) == 4);
    for (int target : {1, 2, 3, 4}) assert(ThermalPresentationScale(target, 4, true, 3) == 1);
    assert(ThermalPresentationFPS(0) == 60 && ThermalPresentationFPS(3) == 30);
    ConfigureSpatialUpscale(2);
    const auto session = GetSpatialUpscaleConfig();
    assert(SpatialUpscaleInputScale() == 2);
    mobile_applied_thermal_state.store(2);
    assert(SpatialUpscaleInputScale() == 0 && SpatialUpscaleStatus() == 0);
    assert(SpatialUpscaleConfiguredInputScale() == 2);
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

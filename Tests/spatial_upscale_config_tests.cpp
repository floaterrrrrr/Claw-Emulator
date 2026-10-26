// SPDX-License-Identifier: GPL-3.0-or-later
#include "SpatialUpscaleConfig.hpp"
#include "SpatialExtent.hpp"
#include <cassert>
#include <iostream>

int main() {
    Claw::ConfigureSpatialUpscale(3);
    const auto old = Claw::GetSpatialUpscaleConfig();
    assert(Claw::SpatialUpscaleInputScale() == 2 && Claw::SpatialUpscaleStatus() == 2);
    old->encoded.store(true);
    assert(Claw::SpatialUpscaleStatus() == 1);
    old->Fail("fixture allocation failure");
    old->Fail("later failure must not hide the first cause");
    assert(Claw::SpatialUpscaleFailureReason() == "fixture allocation failure");
    assert(Claw::SpatialUpscaleInputScale() == 0 && Claw::SpatialUpscaleStatus() == -1);
    Claw::ConfigureSpatialUpscale(2);
    old->failed.store(true); // A delayed old command must not affect the replacement.
    assert(Claw::SpatialUpscaleInputScale() == 2 && Claw::SpatialUpscaleStatus() == 2);
    Claw::ConfigureSpatialUpscale(0);
    assert(Claw::SpatialUpscaleStatus() == 0);
    Claw::ConfigureSpatialUpscale(8);
    assert(!Claw::GetSpatialUpscaleConfig());
    constexpr auto top = Claw::SpatialExtent::For2x(800, 480, 1600, 960);
    constexpr auto bottom = Claw::SpatialExtent::For2x(640, 480, 1280, 960);
    static_assert(top && bottom && top.padded_width == 1024 && bottom.padded_width == 1024 &&
                  top.padded_height == 512 && bottom.padded_height == 512);
    static_assert(!Claw::SpatialExtent::For2x(1200, 720, 1600, 960));
    static_assert(!Claw::SpatialExtent::For2x(0, 480, 1600, 960));
    std::cout << "PASS: MetalFX configuration, failure fallback, and session callback isolation\n";
}

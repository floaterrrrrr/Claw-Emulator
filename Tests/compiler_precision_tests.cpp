// SPDX-License-Identifier: GPL-3.0-or-later
#include <bit>
#include <cassert>
#include <cmath>
#include <iostream>
#include <limits>
#include "ClawCore.h"
#include "video_core/pica_types.h"

int main() {
    // PICA explicitly maps 0*infinity to zero but must retain a genuine NaN.
    // Global fast-math removes the checks implementing these guest semantics.
    using Float = Pica::Float<16, 7>;
    volatile float source_inf = std::numeric_limits<float>::infinity();
    volatile float source_nan = std::numeric_limits<float>::quiet_NaN();
    const auto infinity = Float::FromFloat32(source_inf);
    const auto nan = Float::FromFloat32(source_nan);
    assert((Float::Zero() * infinity).ToFloat32() == 0.0f);
    assert(std::isnan((Float::One() * nan).ToFloat32()));
    assert(std::signbit(Float::FromFloat32(-0.0f).ToFloat32()));
    const auto touch = Claw3DSMapTouch(source_nan, 0, 400, 240, 1600, 960);
    assert(touch.x == -1 && touch.y == -1);
    assert(Claw3DSPresentationScale(4) == 4);
    std::cout << "PASS: O3/full-LTO preserves PICA 0*inf, NaN, signed zero, finite touch guards, 4x presentation\n";
}

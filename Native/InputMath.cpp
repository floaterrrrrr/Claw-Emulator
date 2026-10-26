// SPDX-License-Identifier: GPL-3.0-or-later
#include "ClawCore.h"
#include <algorithm>
#include <cmath>

int Claw3DSResolutionScale(int requested) { return std::clamp(requested, 1, 4); }
int Claw3DSPresentationScale(int requested) { return Claw3DSResolutionScale(requested); }

Claw3DSTouchPoint Claw3DSMapTouch(float x, float y, float width, float height,
                          int framebufferWidth, int framebufferHeight) {
    if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(width) || !std::isfinite(height) ||
        width <= 0 || height <= 0 || framebufferWidth <= 0 || framebufferHeight <= 0) {
        return {-1, -1};
    }
    return {std::clamp(x / width, 0.f, 1.f) * (framebufferWidth - 1),
            std::clamp(y / height, 0.f, 1.f) * (framebufferHeight - 1)};
}

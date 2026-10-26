// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <bit>
#include <cstdint>

namespace Claw {
// Padding belongs only to MetalFX's scratch input. Guest textures, exported
// images, viewports and output drawables retain their logical dimensions.
struct SpatialExtent {
    uint32_t content_width{}, content_height{}, padded_width{}, padded_height{};
    uint32_t output_width{}, output_height{};
    static constexpr SpatialExtent For2x(uint32_t width, uint32_t height,
                                         uint32_t output_width, uint32_t output_height) {
        if (!width || !height || width > 2048 || height > 2048 ||
            output_width != width * 2 || output_height != height * 2)
            return {};
        return {width, height, std::bit_ceil(width), std::bit_ceil(height),
                output_width, output_height};
    }
    constexpr explicit operator bool() const { return content_width != 0; }
};
} // namespace Claw

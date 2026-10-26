// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <array>
#include <cassert>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <iostream>

namespace MetalFXTest {
inline uint32_t Color(unsigned column, unsigned row, unsigned cycle, unsigned slot) {
    constexpr std::array<uint32_t, 8> colors{
        0xffd04020, 0xff2080d0, 0xff50c040, 0xffb050b0,
        0xffd0b030, 0xff30b0c0, 0xff8040d0, 0xffd06070};
    return colors[(column + row * 3 + cycle + slot) % colors.size()];
}
inline uint32_t Pixel(unsigned width, unsigned height, unsigned x, unsigned y,
                      unsigned cycle, unsigned slot) {
    return Color(x * 8 / width, y * 3 / height, cycle, slot);
}
inline void Verify(const uint8_t* bytes, size_t stride, unsigned width, unsigned height,
                   unsigned cycle, unsigned slot) {
    auto check = [&](unsigned x, unsigned y) {
        const auto expected = Pixel(width, height, x, y, cycle, slot);
        const auto* actual = bytes + y * stride + x * 4;
        for (unsigned channel = 0; channel < 4; ++channel) {
            const int target = (expected >> (channel * 8)) & 255;
            if (std::abs(int(actual[channel]) - target) > 12) {
                std::cerr << "MetalFX pattern mismatch: slot " << slot << " cycle " << cycle
                          << " coordinate " << x << ',' << y << " channel " << channel
                          << " expected " << target << " actual " << int(actual[channel]) << '\n';
                assert(false && "Stride, content crop, screen mapping or stale frame regression");
            }
        }
    };
    // Asymmetric horizontal and vertical regions catch row-pitch mistakes,
    // screen aspect distortion, stale slot reuse and sampling the padded border.
    for (unsigned row = 0; row < 3; ++row)
        for (unsigned column = 0; column < 8; ++column)
            check(width * (2 * column + 1) / 16, height * (2 * row + 1) / 6);
    for (unsigned y : {8u, height - 9})
        for (unsigned x : {8u, width - 9}) check(x, y);
}
} // namespace MetalFXTest

// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <span>

namespace AudioCore {
// Producer-only variable-rate interpolation for accelerated playback. Rate
// changes preserve phase and samples, rather than rebuilding an AudioConverter
// and repeatedly discarding its history. Normal 1x keeps ApplePCMConverter.
class FastForwardPCM {
public:
    void Reset() noexcept { position = count = 0; ready = have_first = false; phase = 0; step = 0; }
    template<class Input>
    std::size_t Convert(std::span<std::int16_t> output, Input&& input, double achieved_speed,
                        unsigned native_rate = 32728, unsigned output_rate = 48000) {
        if (!native_rate || !output_rate || !std::isfinite(achieved_speed)) return 0;
        const double target = static_cast<double>(native_rate) / output_rate *
                              std::clamp(achieved_speed, 0.5, 2.0);
        if (!step) step = target;
        const auto read = [&](std::array<std::int16_t, 2>& frame) {
            if (position == count) {
                count = std::min<std::size_t>(input(scratch.data(), scratch.size() / 2), scratch.size() / 2);
                position = 0;
                if (!count) return false;
            }
            frame = {scratch[position * 2], scratch[position * 2 + 1]};
            ++position;
            return true;
        };
        std::size_t written = 0;
        while (written < output.size() / 2) {
            if (!ready) {
                // Retain a lone first sample until a second one is available.
                if (!have_first) { if (!read(first)) break; have_first = true; }
                if (!read(second)) break;
                ready = true;
            }
            bool available = true;
            while (phase >= 1) {
                std::array<std::int16_t, 2> next;
                if (!read(next)) { available = false; break; }
                first = second; second = next; phase -= 1;
            }
            if (!available) break;
            for (unsigned channel = 0; channel < 2; ++channel)
                output[written * 2 + channel] = static_cast<std::int16_t>(
                    first[channel] + (second[channel] - first[channel]) * phase);
            // Smooth rate changes over about 20ms without resetting history.
            step += (target - step) * 0.001;
            phase += step;
            ++written;
        }
        return written;
    }
private:
    std::array<std::int16_t, 2048> scratch{};
    std::array<std::int16_t, 2> first{}, second{};
    std::size_t position{}, count{};
    bool ready{}, have_first{};
    double phase{}, step{};
};
} // namespace AudioCore

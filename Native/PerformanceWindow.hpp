// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>

namespace Claw {
// The existing 500 ms sampler supplies these values: no per-frame clock reads,
// allocations or new workers. Reset on resume to exclude menu/older-mode time.
class PerformanceWindow {
public:
    struct Summary {
        double seconds = 0, mean = 0, minimum = 0, maximum = 0;
        std::size_t samples = 0;
    };
    void Reset() noexcept { next = count = 0; }
    void Add(double speed, double seconds) noexcept {
        if (!std::isfinite(speed) || !std::isfinite(seconds) || speed < 0 || seconds <= 0) return;
        values[next] = {speed, seconds};
        next = (next + 1) % values.size();
        count = std::min(count + 1, values.size());
    }
    Summary Get() const noexcept {
        Summary result;
        if (!count) return result;
        result.samples = count;
        result.minimum = result.maximum = values[0].speed;
        for (std::size_t i = 0; i < count; ++i) {
            const auto& value = values[i];
            result.seconds += value.seconds;
            result.mean += value.speed * value.seconds;
            result.minimum = std::min(result.minimum, value.speed);
            result.maximum = std::max(result.maximum, value.speed);
        }
        result.mean /= result.seconds;
        return result;
    }
private:
    struct Sample { double speed = 0, seconds = 0; };
    std::array<Sample, 20> values{};
    std::size_t next = 0, count = 0;
};
} // namespace Claw

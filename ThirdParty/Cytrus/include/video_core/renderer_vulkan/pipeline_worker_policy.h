// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <algorithm>
#include <cstddef>

namespace Vulkan {

// MoltenVK pipeline compilation shares a driver-owned shader library cache.
// Keep shader translation on its separate pool, but admit one pipeline job.
constexpr std::size_t PipelineWorkerCount(bool moltenvk, std::size_t requested) {
    return moltenvk ? 1 : std::max(std::size_t{1}, requested);
}

// Metal pipeline creation has no interruptible deadline. Keep startup's
// optional work budget at zero and admit background jobs after presentation.
class PipelineWarmupPolicy {
public:
    void BeginLoading() { presented = false; }
    bool ObserveFrame(bool completed) {
        const bool first = completed && !presented;
        presented = presented || completed;
        return first;
    }
    bool AllowsBackgroundWork() const { return presented; }

private:
    bool presented{};
};

} // namespace Vulkan

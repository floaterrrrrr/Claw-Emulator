// SPDX-License-Identifier: GPL-3.0-or-later
#include "video_core/renderer_vulkan/descriptor_binding_range.h"
#include <array>
#include <cassert>
#include <iostream>

int main() {
    std::array<unsigned, 3> previous{10, 20, 30};
    auto next = previous;
    const auto check = [&](std::size_t first, std::size_t count, bool offsets = false,
                           bool invalidated = false) {
        const auto changed = Vulkan::ChangedDescriptorRange(previous, next, offsets, invalidated);
        assert(changed.first == first && changed.count == count);
    };
    check(0, 0);
    check(0, 3, false, true); // New command buffer or incompatible utility pipeline.
    check(0, 1, true);        // Uniform dynamic offsets live in set zero.
    next[2] = 31;
    check(2, 1);
    next[1] = 21;
    check(1, 2);
    next[1] = 20;
    next[0] = 11;
    check(0, 3);
    next = previous;
    check(0, 0);
    std::cout << "PASS: changed descriptor ranges retain dynamic offsets and full invalidation\n";
}

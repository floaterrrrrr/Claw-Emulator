// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#include <array>
#include <cstddef>

namespace Vulkan {

struct DescriptorBindingRange {
    std::size_t first{};
    std::size_t count{};
};

// All dynamic uniform descriptors are in set zero. Other descriptor sets can
// remain bound when only texture/utility bindings change. Returning one range
// keeps each draw to at most one Vulkan call, including after a command-buffer
// reset or an intervening utility pipeline with an incompatible layout.
template <typename Set, std::size_t Count>
DescriptorBindingRange ChangedDescriptorRange(const std::array<Set, Count>& previous,
                                              const std::array<Set, Count>& next,
                                              bool offsets_changed, bool invalidated) noexcept {
    static_assert(Count > 0);
    if (invalidated) return {0, Count};
    std::size_t first = Count;
    std::size_t end = 0;
    for (std::size_t index = 0; index < Count; ++index) {
        if (previous[index] != next[index] || (index == 0 && offsets_changed)) {
            if (first == Count) first = index;
            end = index + 1;
        }
    }
    return end ? DescriptorBindingRange{first, end - first} : DescriptorBindingRange{};
}

} // namespace Vulkan

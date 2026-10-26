// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cstdint>

namespace Claw {

// The rasterizer owns this tracker. A display can skip its presentation only
// while the source range and generation match the last submitted frame.
class DisplayDirtyGeneration {
public:
    std::uint64_t Observe(std::uint32_t address, std::uint32_t size) {
        if (address != source_address || size != source_size) {
            source_address = address;
            source_size = size;
            ++generation;
        }
        return generation;
    }

    void MarkWrite(std::uint32_t address, std::uint32_t size) {
        if (size && source_size &&
            static_cast<std::uint64_t>(address) <
                static_cast<std::uint64_t>(source_address) + source_size &&
            static_cast<std::uint64_t>(source_address) <
                static_cast<std::uint64_t>(address) + size) {
            ++generation;
        }
    }

    void Reset() { ++generation; }

private:
    std::uint32_t source_address{};
    std::uint32_t source_size{};
    std::uint64_t generation{1};
};

} // namespace Claw

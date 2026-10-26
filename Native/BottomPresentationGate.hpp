// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <array>
#include <cstdint>

namespace Claw {

using BottomPresentationKey = std::array<std::uint64_t, 32>;

class BottomPresentationGate {
public:
    bool CanSkip(const BottomPresentationKey& key) const {
        return has_presented && key == last_presented;
    }

    // Only call after submitting the lower display frame. Skipping never
    // advances this record, so the next rasterizer write still forces a draw.
    void DidPresent(const BottomPresentationKey& key) {
        last_presented = key;
        has_presented = true;
    }

    void Invalidate() { has_presented = false; }

private:
    BottomPresentationKey last_presented{};
    bool has_presented = false;
};

} // namespace Claw

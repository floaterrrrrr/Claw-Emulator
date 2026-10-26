// SPDX-License-Identifier: GPL-3.0-or-later
#include "BottomPresentationGate.hpp"
#include "DisplayDirtyGeneration.hpp"
#include "VulkanPipelineBlob.hpp"
#include <cassert>
#include <cstdint>
#include <iostream>
#include <vector>

int main() {
    Claw::DisplayDirtyGeneration dirty;
    Claw::BottomPresentationGate gate;
    Claw::BottomPresentationKey key{};
    key[0] = dirty.Observe(0x18000000, 0x2000);
    assert(!gate.CanSkip(key)); // first frame needs a real image
    gate.DidPresent(key);
    assert(gate.CanSkip(key));

    // Unrelated GPU activity leaves the bottom image reusable.
    dirty.MarkWrite(0x18004000, 0x100);
    assert(dirty.Observe(0x18000000, 0x2000) == key[0]);
    assert(gate.CanSkip(key));

    // Touch UI / animated lower-screen writes advance the source generation.
    dirty.MarkWrite(0x18001000, 0x40);
    auto changed = key;
    changed[0] = dirty.Observe(0x18000000, 0x2000);
    assert(!gate.CanSkip(changed));
    // A skipped frame must not acknowledge the write.
    assert(!gate.CanSkip(changed));
    gate.DidPresent(changed);
    assert(gate.CanSkip(changed));

    // Matrix change and core resume always force another first frame.
    auto rotated = changed;
    rotated[9]++;
    assert(!gate.CanSkip(rotated));
    gate.DidPresent(rotated);
    gate.Invalidate();
    assert(!gate.CanSkip(rotated));
    gate.DidPresent(rotated);
    dirty.Reset(); // save-state load / rasterizer purge
    rotated[0] = dirty.Observe(0x18000000, 0x2000);
    assert(!gate.CanSkip(rotated));

    const std::vector<std::uint8_t> vulkan_data{1, 2, 3, 4};
    auto blob = Claw::EncodePipelineBlob(vulkan_data, "engine-v1-moltenvk-v1", 123);
    auto decoded = Claw::DecodePipelineBlob(blob, "engine-v1-moltenvk-v1", 123);
    assert(decoded && std::vector<std::uint8_t>(decoded->begin(), decoded->end()) == vulkan_data);
    assert(!Claw::DecodePipelineBlob(blob, "engine-v2-moltenvk-v1", 123));
    assert(!Claw::DecodePipelineBlob(blob, "engine-v1-moltenvk-v1", 124));
    blob.pop_back();
    assert(!Claw::DecodePipelineBlob(blob, "engine-v1-moltenvk-v1", 123));
    std::cout << "PASS: bottom display writes, skips, warmups, and pipeline blob validation\n";
}

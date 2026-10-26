// SPDX-License-Identifier: GPL-3.0-or-later
#include "core/arm/fastinterp/fastinterp_cache.h"
#include <cassert>
#include <cstdint>
#include <iostream>
#include <memory>
#include <vector>

using namespace Core::FastInterp;
static_assert(MAX_BLOCK_GUEST_BYTES == 132);

struct LiveBlock {
    u32 start;
    u32 end;
    BasicBlock* block;
};

static void check_range(u32 invalidate_start, u32 length) {
    auto cache = std::make_unique<BlockCache>();
    std::vector<u32> candidates;
    for (u32 index = 0; index < 4096; ++index) {
        const u32 pc = 0x100000 + index * 13;
        bool hit = false;
        BasicBlock* block = cache->LookupOrAllocate(pc, hit);
        block->end_pc = pc + 1 + index % MAX_BLOCK_GUEST_BYTES;
        block->inst_count = 1;
        block->chain_target = block;
        candidates.push_back(pc);
    }
    // Exercise the maximum real decoded block span and address-space ceiling.
    for (u32 pc : {0x100000u, 0x100080u, 0x100082u, 0x100083u,
                   0xFFFFFE00u, 0xFFFFFE80u}) {
        bool hit = false;
        BasicBlock* block = cache->LookupOrAllocate(pc, hit);
        block->end_pc = pc + MAX_BLOCK_GUEST_BYTES;
        block->inst_count = 1;
        block->chain_target = block;
        candidates.push_back(pc);
    }
    std::vector<LiveBlock> live;
    for (u32 pc : candidates) {
        if (auto* block = cache->Lookup(pc)) live.push_back({pc, block->end_pc, block});
    }
    cache->InvalidateRange(invalidate_start, length);
    const uint64_t end = static_cast<uint64_t>(invalidate_start) + length;
    for (const auto& entry : live) {
        const bool overlaps = length != 0 && entry.start < end && entry.end > invalidate_start;
        assert((cache->Lookup(entry.start) == nullptr) == overlaps);
        if (overlaps) {
            assert(entry.block->inst_count == 0);
            assert(entry.block->chain_target == nullptr);
        }
    }
}

int main() {
    for (u32 length : {0u, 1u, 2u, 4u, 128u, 256u, 257u, 4096u}) {
        for (u32 start : {0u, 0x100000u, 0x100081u, 0x100100u,
                          0x102000u, 0xFFFFFE80u, 0xFFFFFFFFu}) {
            check_range(start, length);
        }
    }
    std::cout << "PASS: short and large interpreter cache invalidations match range overlap, including odd PCs and address-space limits\n";
}

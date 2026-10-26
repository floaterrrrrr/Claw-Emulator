// SPDX-License-Identifier: GPL-3.0-or-later
#include "core/memory.h"
#include <cassert>
#include <iostream>
#include <type_traits>

using namespace Memory;
static_assert(std::is_trivially_copyable_v<RasterizerVirtualAddresses>);
static_assert(sizeof(RasterizerVirtualAddresses) <= 16);

static void check(PAddr address, PAddr plugin, VAddr first = 0, VAddr second = 0) {
    const auto aliases = RasterizerVirtualAliases(address, plugin);
    assert(aliases.count == (second ? 2U : first ? 1U : 0U));
    if (first) assert(aliases.addresses[0] == first);
    if (second) assert(aliases.addresses[1] == second);
}

int main() {
    check(VRAM_PADDR - 1, 0);
    check(VRAM_PADDR, 0, VRAM_VADDR);
    check(VRAM_PADDR_END - 1, 0, VRAM_VADDR_END - 1);
    check(VRAM_PADDR_END, 0);
    check(FCRAM_PADDR - 1, 0);
    check(FCRAM_PADDR, 0, LINEAR_HEAP_VADDR, NEW_LINEAR_HEAP_VADDR);
    check(FCRAM_PADDR_END - 1, 0, LINEAR_HEAP_VADDR + static_cast<VAddr>(FCRAM_SIZE) - 1,
          NEW_LINEAR_HEAP_VADDR + static_cast<VAddr>(FCRAM_SIZE) - 1);
    check(FCRAM_PADDR_END, 0, NEW_LINEAR_HEAP_VADDR + static_cast<VAddr>(FCRAM_SIZE));
    check(FCRAM_N3DS_PADDR_END - 1, 0, NEW_LINEAR_HEAP_VADDR_END - 1);
    check(FCRAM_N3DS_PADDR_END, 0);
    constexpr PAddr plugin = FCRAM_PADDR + 0x10000;
    check(plugin - 1, plugin, LINEAR_HEAP_VADDR + 0xFFFF,
          NEW_LINEAR_HEAP_VADDR + 0xFFFF);
    check(plugin, plugin, PLUGIN_3GX_FB_VADDR);
    check(plugin + PLUGIN_3GX_FB_SIZE - 1, plugin, PLUGIN_3GX_FB_VADDR_END - 1);
    check(plugin + PLUGIN_3GX_FB_SIZE, plugin,
          LINEAR_HEAP_VADDR + 0x10000 + PLUGIN_3GX_FB_SIZE,
          NEW_LINEAR_HEAP_VADDR + 0x10000 + PLUGIN_3GX_FB_SIZE);
    check(0, plugin);
    check(0xFFFFFFFF, plugin);
    std::cout << "PASS: allocation-free rasterizer aliases at VRAM, FCRAM, New 3DS and plugin boundaries\n";
}

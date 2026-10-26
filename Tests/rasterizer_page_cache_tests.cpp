// SPDX-License-Identifier: GPL-3.0-or-later
#include <algorithm>
#include <array>
#include <cassert>
#include <iostream>
#include <map>
#include <random>
#include <vector>
#include <boost/icl/interval_map.hpp>
#include <boost/icl/interval_set.hpp>
#include <boost/icl/right_open_interval.hpp>
#include <boost/range/iterator_range.hpp>
#include "core/memory.h"
#include "video_core/rasterizer_cache/slot_id.h"

#if defined(NDEBUG) || defined(BOOST_DISABLE_ASSERTS)
#error Page cache regressions must run with C and Boost assertions enabled
#endif

#undef ASSERT
#define ASSERT(condition) assert(condition)

namespace VideoCore {
using PageMap = boost::icl::interval_map<u32, int>;

constexpr auto RangeFromInterval(const auto& map, const auto& interval) {
    return boost::make_iterator_range(map.equal_range(interval));
}

struct PageTable {
    std::map<u32, bool> cached;
    unsigned changes = 0;
    void RasterizerMarkRegionCached(PAddr start, u32 size, bool value) {
        using namespace Memory;
        assert(size && !(start & CITRA_PAGE_MASK) && !(size & CITRA_PAGE_MASK));
        const u64 end = u64{start} + size;
        assert((start >= VRAM_PADDR && end <= VRAM_PADDR_END) ||
               (start >= FCRAM_PADDR && end <= FCRAM_N3DS_PADDR_END));
        for (u64 address = start; address < end; address += CITRA_PAGE_SIZE) {
            const auto page = static_cast<u32>(address >> CITRA_PAGE_BITS);
            assert(cached[page] != value); // No duplicate cache/uncache transitions.
            cached[page] = value;
            ++changes;
        }
    }
};

template <class T>
class RasterizerCache {
public:
    void UpdatePagesCachedCount(PAddr addr, u32 size, int delta);
    PageMap cached_pages;
    PageTable memory;
};
} // namespace VideoCore

static void interval_lookup_regression() {
    // Upstream issue 51 / PR 54: queries overlapping several disjoint keys
    // require heterogeneous lookup with libc++ 22 and later.
    using Map = VideoCore::PageMap;
    using Interval = Map::interval_type;
    Map map;
    for (const auto start : {0U, 20U, 40U}) {
        map.add({Interval::right_open(start, start + 10), 1});
    }
    const auto query = Interval::right_open(5, 25);
    assert(map.lower_bound(query)->first == Interval::right_open(0, 10));
    assert(map.upper_bound(query)->first == Interval::right_open(40, 50));
    assert(map.find(query)->first == Interval::right_open(0, 10));
    const auto [begin, end] = map.equal_range(query);
    assert(std::distance(begin, end) == 2);
    assert(map.find(Interval::right_open(10, 20)) == map.end());
    map.add({query, 1}); // Splits, fills the gap, and joins adjacent segments.
    for (u32 page = 0; page < 50; ++page) {
        const int expected = ((page < 10 || (page >= 20 && page < 30) || page >= 40) ? 1 : 0) +
                             ((page >= 5 && page < 25) ? 1 : 0);
        assert(map(page) == expected);
    }
    map.add({query, -1});
    assert(map.iterative_size() == 3);

    using Set = boost::icl::interval_set<int, std::less, boost::icl::right_open_interval<int>>;
    using Itv = Set::interval_type;
    Set set;
    for (const auto& interval : {Itv(0, 2), Itv(3, 5), Itv(6, 9), Itv(10, 12)}) {
        set.add(interval);
    }
    assert(*set.lower_bound(Itv(4, 7)) == Itv(3, 5));
    assert(*set.upper_bound(Itv(4, 7)) == Itv(10, 12));

    // The other rasterizer ICL map stores surface ownership, not integer
    // counts. Exercise its explicit right-open interval and SlotId codomain.
    using SurfaceInterval = boost::icl::right_open_interval<PAddr>;
    using SurfaceMap = boost::icl::interval_map<PAddr, VideoCore::SurfaceId,
        boost::icl::partial_absorber, std::less, boost::icl::inplace_plus,
        boost::icl::inter_section, SurfaceInterval>;
    SurfaceMap dirty;
    dirty.set({SurfaceInterval(0, 10), VideoCore::SurfaceId{2}});
    dirty.set({SurfaceInterval(20, 30), VideoCore::SurfaceId{3}});
    dirty.set({SurfaceInterval(5, 25), VideoCore::SurfaceId{4}});
    assert(dirty(0) == VideoCore::SurfaceId{2});
    assert(dirty(5) == VideoCore::SurfaceId{4});
    assert(dirty(24) == VideoCore::SurfaceId{4});
    assert(dirty(25) == VideoCore::SurfaceId{3});
    dirty.erase(SurfaceInterval(5, 25));
    assert(dirty.find(SurfaceInterval(5, 25)) == dirty.end());
    assert(dirty.iterative_size() == 2);
}

static void bounds_regression() {
    using namespace Memory;
    VideoCore::RasterizerCache<int> cache;
    for (auto [start, size] : {std::pair<u32, u32>{0, 0}, {VRAM_PADDR, 0},
                             {0, 1}, {0xFFFFF000U, 0x2000}, {VRAM_PADDR_END, 1},
                             {FCRAM_N3DS_PADDR_END, 1}}) {
        cache.UpdatePagesCachedCount(start, size, 1);
    }
    cache.UpdatePagesCachedCount(VRAM_PADDR, CITRA_PAGE_SIZE, 0);
    assert(cache.cached_pages.empty() && cache.memory.changes == 0);
    for (auto [start, size, pages] : {
             std::array<u32, 3>{VRAM_PADDR - 1, 2, 1},
             {VRAM_PADDR_END - 1, 2, 1}, {FCRAM_PADDR - 1, 2, 1},
             {FCRAM_PADDR_END - 1, 2, 2}, {FCRAM_N3DS_PADDR_END - 1, 2, 1},
             {VRAM_PADDR + 1, CITRA_PAGE_SIZE, 2}}) {
        const auto before = cache.memory.changes;
        cache.UpdatePagesCachedCount(start, size, 1);
        assert(cache.memory.changes == before + pages);
        cache.UpdatePagesCachedCount(start, size, -1);
        assert(cache.memory.changes == before + 2 * pages);
        assert(cache.cached_pages.empty());
    }
    // A request spanning both regions must skip the unmapped gap and avoid
    // wrapping its exclusive end back into low memory.
    const auto before = cache.memory.changes;
    cache.UpdatePagesCachedCount(1, 0xFFFFFFFF, 1);
    constexpr u32 valid_pages = (VRAM_SIZE + FCRAM_N3DS_SIZE) / CITRA_PAGE_SIZE;
    assert(cache.memory.changes == before + valid_pages);
    cache.UpdatePagesCachedCount(1, 0xFFFFFFFF, -1);
    assert(cache.memory.changes == before + 2 * valid_pages);
    assert(cache.cached_pages.empty());
}

static void overlapping_surface_regression() {
    using namespace Memory;
    VideoCore::RasterizerCache<int> cache;
    std::array<int, 64> expected{};
    std::vector<std::pair<u32, u32>> live;
    std::mt19937 random(114);
    auto update = [&](u32 start, u32 length, int delta) {
        cache.UpdatePagesCachedCount(VRAM_PADDR + start * CITRA_PAGE_SIZE + 1,
                                     length * CITRA_PAGE_SIZE - 1, delta);
        for (u32 page = start; page < start + length; ++page) expected[page] += delta;
        for (u32 page = 0; page < expected.size(); ++page) {
            const auto physical_page = (VRAM_PADDR >> CITRA_PAGE_BITS) + page;
            assert(expected[page] >= 0);
            assert(cache.cached_pages(physical_page) == expected[page]);
            assert(cache.memory.cached[physical_page] == (expected[page] != 0));
        }
    };
    for (unsigned operation = 0; operation < 10000; ++operation) {
        if (live.empty() || (live.size() < 64 && (random() & 1))) {
            const u32 start = random() % 64;
            const u32 length = 1 + random() % (64 - start);
            live.emplace_back(start, length);
            update(start, length, 1);
        } else {
            const auto index = random() % live.size();
            const auto [start, length] = live[index];
            update(start, length, -1);
            live.erase(live.begin() + index);
        }
    }
    for (const auto [start, length] : live) update(start, length, -1);
    assert(cache.cached_pages.empty());
}

int main() {
    interval_lookup_regression();
    bounds_regression();
    overlapping_surface_regression();
    std::cout << "PASS: ICL overlap lookup; empty/overflow/VRAM/FCRAM bounds; "
                 "10,000 surface registrations with balanced page-table transitions (assertions ON)\n";
}

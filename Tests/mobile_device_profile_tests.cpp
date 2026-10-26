// SPDX-License-Identifier: GPL-3.0-or-later
#include "MobileDeviceProfile.hpp"
#include "MobileTransitionCache.hpp"
#include <cassert>
#include <iostream>
#include <limits>

int main() {
    using namespace Claw;
    constexpr uint64_t GiB = 1024 * MiB;
    // All supported iPhone hardware generations, including future identifiers.
    // Automatic rendering prioritizes frame-time headroom, including on modern phones.
    for (unsigned generation = 11; generation <= 20; ++generation) {
        const bool modern_gpu = generation >= 15;
        const auto selected = SelectMobileGraphicsProfile({modern_gpu, 8 * GiB, 512 * MiB,
                                                           generation, true, false});
        assert(selected.cpu_clock == 100);
        assert(selected.resolution == (generation <= 12 ? 1 : 2));
        assert(selected.metalfx_input == 0);
    }
    assert(SelectMobileGraphicsProfile({true, 8 * GiB, 512 * MiB, 18, false}).resolution == 2);
    assert(SelectMobileGraphicsProfile({false, 8 * GiB, 512 * MiB, 18, true}).resolution == 2);
    assert(SelectMobileGraphicsProfile({true, 3 * GiB, 512 * MiB, 18, true}).resolution == 1);
    assert(SelectMobileGraphicsProfile({true, 8 * GiB, 512 * MiB, 0, true}).resolution == 2);
    assert(SelectMobileGraphicsProfile({true, 64 * GiB, 512 * MiB, 18, true, true}).resolution == 1);
    assert(SelectMobileGraphicsProfile({}).resolution == 2);
    assert(SelectMobileMemoryProfile({false, 3 * GiB, 256 * MiB, 11}).cache_bytes == 8 * MiB);
    assert(SelectMobileMemoryProfile({false, 4 * GiB, 256 * MiB, 13}).cache_bytes == 12 * MiB);
    const auto a15 = SelectMobileMemoryProfile({false, 6 * GiB, 256 * MiB});
    const auto modern = SelectMobileMemoryProfile({true, 8 * GiB, 1024 * MiB});
    assert(a15.legacy_gpu && a15.cache_bytes == 12 * MiB && a15.retained_surfaces == 4);
    assert(a15.max_idle_frames == 4 && a15.upload_buffer_bytes == 128 * MiB);
    assert(!modern.legacy_gpu && modern.cache_bytes == 32 * MiB && modern.retained_surfaces == 8);
    assert(!modern.max_idle_frames && modern.upload_buffer_bytes == 512 * MiB);
    assert(SelectMobileMemoryProfile({true, 6 * GiB, 256 * MiB, 14}).legacy_gpu);
    assert(SelectMobileMemoryProfile({false, 0, 0}).legacy_gpu); // Failed/unknown probe is conservative.
    assert(SelectMobileMemoryProfile({true, 4 * GiB, 256 * MiB}).legacy_gpu);
    assert(SelectMobileMemoryProfile({true, 8 * GiB, 64 * MiB}).upload_buffer_bytes == 64 * MiB);
    assert(ConfigureMobileMemoryProfile({false, 6 * GiB, 256 * MiB}).legacy_gpu);
    assert(GetMobileMemoryProfile().upload_buffer_bytes == 128 * MiB);
    ResetTransitionCache();

    TransitionRetention<unsigned> budget;
    budget.BeginFrame();
    assert(!budget.Keep(99, 1, 10, 10)); // Must not retain/reuse in-flight resources.
    assert(!budget.Keep(99, std::numeric_limits<uint64_t>::max(), 9, 10));
    assert(!budget.Keep(99, 0, 9, 10));
    for (unsigned id = 1; id <= 4; ++id) assert(budget.Keep(id, 3 * MiB, 9, 10));
    assert(budget.Full() && !budget.Keep(5, 1, 9, 10));
    for (unsigned id = 1; id <= 4; ++id) assert(budget.Contains(id));

    // Four actual TickFrame selections, then evict; submission-count changes
    // cannot prematurely expire a target. Reuse with a new tick starts a new age.
    TransitionRetention<unsigned> age(a15);
    for (unsigned frame = 0; frame < 4; ++frame) {
        age.BeginFrame();
        assert(age.Keep(1, MiB, 10, 1000 + frame * 100));
    }
    age.BeginFrame();
    assert(!age.Keep(1, MiB, 10, 2000));
    assert(!age.Contains(1));
    assert(age.Keep(1, MiB, 20, 2000));
    age.BeginFrame();
    assert(!age.Keep(1, MiB, 2000, 2000));
    age.BeginFrame();
    assert(age.Keep(1, MiB, 2000, 2001));
    ReleaseTransitionCache();
    age.BeginFrame();
    assert(!age.Keep(1, MiB, 2000, 2001) && !age.Contains(1));
    ResetTransitionCache();
    age.BeginFrame();
    assert(age.Keep(1, MiB, 2000, 2001));

    // iPhone 17 keeps the existing long-lived retention and staging policy.
    ConfigureMobileMemoryProfile({true, 8 * GiB, 1024 * MiB});
    assert(!GetMobileMemoryProfile().legacy_gpu);
    TransitionRetention<unsigned> modern_age;
    for (unsigned frame = 0; frame < 100; ++frame) {
        modern_age.BeginFrame();
        assert(modern_age.Keep(1, MiB, 9, 10));
    }
    std::cout << "PASS: legacy 8–12MiB/4-surface/4-idle-frame limits, 128MiB upload ring, GPU completion/reuse/pressure guards; modern policy preserved\n";
}

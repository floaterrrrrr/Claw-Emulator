// SPDX-License-Identifier: GPL-3.0-or-later
#include "MobilePresentation.hpp"
#include "MobileTransitionCache.hpp"
#include <array>
#include <cassert>
#include <iostream>
enum class Mode { Immediate, Mailbox, Fifo, Other };
int main() {
    using namespace std::chrono_literals;
    Claw::FastForwardPresentation fast;
    const auto start = Claw::FastForwardPresentation::Clock::time_point{};
    assert(fast.Due(start));
    for (const auto offset : {4ms, 8ms, 12ms, 16ms}) assert(!fast.Due(start + offset));
    assert(fast.Due(start + 17ms));
    assert(!fast.Due(start + 18ms));
    assert(fast.Due(start + 18ms, true)); // screenshot can force a real presentation
    assert(!fast.Due(start + 19ms));
    fast.Reset(); // leave/re-enter 4x: first presentation is immediate
    assert(fast.Due(start + 20ms));
    assert(fast.Due(start + 1s)); // no catch-up presentation burst after a pause
    assert(!fast.Due(start + 1s));
    const auto select = [](std::span<const Mode> modes) {
        return Claw::MobilePresentationMode(modes, Mode::Mailbox, Mode::Immediate, Mode::Fifo);
    };
    assert(select(std::array{Mode::Immediate, Mode::Fifo, Mode::Mailbox}) == Mode::Mailbox);
    assert(select(std::array{Mode::Fifo, Mode::Immediate}) == Mode::Immediate);
    assert(select(std::array{Mode::Fifo}) == Mode::Fifo);
    assert(select(std::array{Mode::Other, Mode::Fifo}) == Mode::Fifo);
    Claw::ResetTransitionCache();
    Claw::TransitionRetention<unsigned> cache;
    assert(!cache.Keep(1, 1024, 10, 10)); // still in flight, cannot retain/reuse
    assert(!cache.Keep(1, 17 * 1024 * 1024, 9, 10));
    assert(cache.Keep(1, 16 * 1024 * 1024, 9, 10));
    assert(cache.Keep(2, 16 * 1024 * 1024, 9, 10));
    assert(cache.Full() && cache.Contains(1) && cache.Contains(2));
    assert(!cache.Keep(3, 1, 9, 10));
    Claw::TransitionRetention<unsigned> slots;
    for (unsigned i = 0; i < 8; ++i) assert(slots.Keep(i, 1024, 9, 10));
    assert(!slots.Keep(8, 1024, 9, 10) && slots.Full());
    Claw::ReleaseTransitionCache();
    Claw::TransitionRetention<unsigned> pressure;
    assert(!pressure.Keep(1, 1024, 9, 10));
    Claw::ResetTransitionCache();
    assert(pressure.Keep(1, 1024, 9, 10));
    std::cout << "PASS: 4x latest-frame presentation cadence/reset/screenshot/pause; supported mobile mailbox/immediate selection and mandatory FIFO fallback; bounded 32MB/8-slot completed-texture retention and memory-pressure release\n";
}

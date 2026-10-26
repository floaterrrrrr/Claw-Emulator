// SPDX-License-Identifier: GPL-3.0-or-later
#include "AsyncStateOperation.hpp"
#include "MobileDeviceProfile.hpp"
#include "core/arm/fastinterp/fastinterp_cache.h"
#include <cassert>
#include <future>
#include <iostream>
#include <memory>
using namespace Claw;
static void ready(AsyncStateOperation& operation) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    while (operation.current() == AsyncStateOperation::Phase::Preparing) {
        assert(std::chrono::steady_clock::now() < deadline); std::this_thread::yield();
    }
}
int main() {
    const auto owner = std::this_thread::get_id();
    std::promise<void> releaseDisk;
    auto disk = releaseDisk.get_future();
    std::atomic<bool> captured{}, written{};
    std::atomic<int> wakes{};
    AsyncStateOperation save([] {}, [&] {
        assert(std::this_thread::get_id() != owner); captured = true;
    }, [&] { assert(captured); disk.wait(); written = true; }, [&] { ++wakes; });
    ready(save); assert(save.atBoundary());
    assert(captured && !written); // Guest can resume while persistence is blocked.
    releaseDisk.set_value(); save.join();
    assert(written && save.failure().empty() && wakes == 2 && save.boundaryStarted());
    AsyncStateOperation bad([] { throw std::runtime_error("bad header"); },
                            [] { assert(false); }, [] { assert(false); });
    ready(bad); bad.join(); assert(bad.failure() == "bad header" && !bad.boundaryStarted());
    AsyncStateOperation stopped([] {}, [] { assert(false); }, [] { assert(false); });
    ready(stopped); stopped.join(); assert(!stopped.failure().empty() && !stopped.boundaryStarted());
    AsyncStateOperation captureError([] {}, [] { throw std::runtime_error("capture error"); },
                                    [] { assert(false); });
    ready(captureError); assert(captureError.atBoundary()); captureError.join();
    assert(captureError.failure() == "capture error" && captureError.boundaryStarted());
    assert(IPhoneGeneration("iPhone14,7") == 14 && IPhoneGeneration("iPhone18,3") == 18);
    assert(IPhoneGeneration("iPhone19,1") == 19 && IPhoneGeneration("arm64") == 0);
    assert(IPhoneGeneration("iPhonebad") == 0);
    ConfigureMobileMemoryProfile({true, 8*1024*MiB, 1024*MiB, 18, true});
    assert(SelectMobileGraphicsProfile({true, 8*1024*MiB, 1024*MiB, 18, true}).resolution == 2);
    assert(!GetMobileMemoryProfile().legacy_gpu);
    ConfigureMobileMemoryProfile({false, 6*1024*MiB, 256*MiB, 14});
    assert(GetMobileMemoryProfile().legacy_gpu);
    using namespace Core::FastInterp;
    auto cache = std::make_unique<BlockCache>(); bool hit = false;
    auto* block = cache->LookupOrAllocate(0x1000,hit); assert(!hit);
    block->end_pc = 0x1008; block->inst_count = 1;
    assert(cache->LookupOrAllocate(0x1000,hit)==block && hit);
    cache->InvalidateRange(0x1000,4); assert(cache->Lookup(0x1000)==nullptr);
    cache->LookupOrAllocate(0x1000,hit); assert(!hit);
    cache->Clear(); assert(cache->Lookup(0x1000)==nullptr);
    std::cout << "PASS: background state phases, paused wakeups, cancellation/join/errors, universal profiles and CPU cache invalidation\n";
}

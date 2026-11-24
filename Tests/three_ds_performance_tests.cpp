// SPDX-License-Identifier: GPL-3.0-or-later
#include "ThreeDSPerformance.hpp"
#include "common/thread_worker.h"
#include <cassert>
#include <iostream>
#include <limits>

// Keep the production worker implementation; omit OS-specific thread naming.
namespace Common {
void SetCurrentThreadName(const char*) {}
}

int main() {
    using Claw::ThreeDSAnisotropy;
    static_assert(Claw::DefaultThreeDSAnisotropy);
    assert(Claw::three_ds_anisotropy_enabled.load());
    assert(ThreeDSAnisotropy(true, true, true, true, 16) == 16);
    assert(ThreeDSAnisotropy(true, true, true, true, 64) == 16);
    assert(ThreeDSAnisotropy(true, true, true, true, 8) == 8);
    assert(ThreeDSAnisotropy(true, true, true, true, 2) == 2);
    assert(ThreeDSAnisotropy(false, true, true, true, 16) == 1);
    assert(ThreeDSAnisotropy(true, false, true, true, 16) == 1);
    assert(ThreeDSAnisotropy(true, true, false, true, 16) == 1);
    assert(ThreeDSAnisotropy(true, true, true, false, 16) == 1);
    for (float limit : {0.0f, -1.0f, 1.0f, std::numeric_limits<float>::infinity(),
                        std::numeric_limits<float>::quiet_NaN()}) {
        assert(ThreeDSAnisotropy(true, true, true, true, limit) == 1);
    }
    Claw::three_ds_anisotropy_enabled.store(false);
    assert(ThreeDSAnisotropy(Claw::three_ds_anisotropy_enabled.load(), true, true, true, 16) == 1);

    // The opt-in Utility constructor must preserve queue/drain behavior.
    // Default pools retain inherited QoS; non-iOS hosts perform no QoS call.
    Common::ThreadWorker utility{1, "Test cache writer", {}, Common::ThreadQoS::Utility};
    std::atomic<unsigned> writes{};
    for (unsigned i = 0; i < 64; ++i) utility.QueueWork([&] { ++writes; });
    utility.WaitForRequests();
    assert(writes == 64 && utility.NumWorkers() == 1);
    Common::StatefulThreadWorker<unsigned> inherited{
        1, "Test existing state maker", [](std::size_t index) { return unsigned(index + 7); }};
    std::atomic<unsigned> observed{};
    inherited.QueueWork([&](unsigned* state) { observed = *state; });
    inherited.WaitForRequests();
    assert(observed == 7); // existing three-argument state makers remain compatible
    std::cout << "PASS: default-on anisotropy, 16x/device cap, nearest/unsupported/off guards, utility worker drain\n";
}

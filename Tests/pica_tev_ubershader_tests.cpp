// SPDX-License-Identifier: GPL-3.0-or-later
#include "PicaTevUbershader.hpp"
#include "common/async_handle.h"
#include "common/thread_worker.h"

#include <cassert>
#include <future>
#include <iostream>

namespace Common {
void SetCurrentThreadName(const char*) {}
}

namespace {
struct RawStage {
    std::uint32_t sources_raw, modifiers_raw, ops_raw, scales_raw;
};

constexpr std::array<RawStage, 6> stages{{
    {0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff},
    {0x00040003, 0x00204009, 0x00040008, 0x00020001},
    {}, {}, {},
    {0x000e000f, 0, 0, 0},
}};
constexpr auto packed = Claw::PackPicaTev(stages, 0x1a5, 0x17);
static_assert(packed.stages[0] ==
              std::array<std::uint32_t, 4>{0x0fff0fff, 0x00777fff, 0xf000f, 0x30003});
static_assert(packed.stages[1] ==
              std::array<std::uint32_t, 4>{0x40003, 0x204009, 0x40008, 0x20001});
static_assert(packed.stages[5][0] == 0xe000f);
static_assert(packed.control == std::array<std::uint32_t, 4>{0xa5, 7, 0, 0});
}

int main() {
    using Claw::SelectTevPipeline;
    using enum Claw::TevPipelineChoice;
    assert(SelectTevPipeline(false, false, true, false) == Wait);
    assert(SelectTevPipeline(false, true, false, false) == Skip);
    assert(SelectTevPipeline(false, false, false, true) == Wait);
    assert(SelectTevPipeline(false, true, true, true) == Ubershader);

    // Run handoff across the same completion primitive and worker count used
    // by the renderer. A recorded fallback retains its own per-draw registers.
    Common::AsyncHandle specialized;
    std::promise<void> finish_build;
    auto build_gate = finish_build.get_future();
    int compiled_handle{};
    Common::ThreadWorker worker{1, "Pipeline test", {}, Common::ThreadQoS::Utility};
    worker.QueueWork([&] {
        build_gate.wait();
        compiled_handle = 42;
        specialized.MarkDone();
    });
    const auto recorded_state = packed;
    assert(SelectTevPipeline(specialized.IsDone(), true, true, false) == Ubershader);
    finish_build.set_value();
    specialized.WaitDone();
    assert(SelectTevPipeline(specialized.IsDone(), true, true, false) == Specialized);
    assert(compiled_handle == 42);
    assert(recorded_state.stages[5][0] == 0xe000f);
    worker.WaitForRequests();
    std::cout << "PASS: PICA TEV register packing, fallback selection and async handoff\n";
}

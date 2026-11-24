// SPDX-License-Identifier: GPL-3.0-or-later
#include "common/async_handle.h"
#include "common/thread_worker.h"
#include "video_core/renderer_vulkan/pipeline_worker_policy.h"
#include <cassert>
#include <chrono>
#include <future>
#include <iostream>
#include <vector>

// Exercise the real worker without linking platform-specific thread naming.
namespace Common {
void SetCurrentThreadName(const char*) {}
}

namespace {
using namespace std::chrono_literals;
using Common::WorkPriority;

void CheckPriorityAndPromotion() {
    Common::ThreadWorker worker{1, "Priority test"};
    std::vector<int> order;
    std::promise<void> release;
    auto gate = release.get_future();
    worker.QueueWork([&] { gate.wait(); });

    const auto warmup = worker.QueueWork([&] { order.push_back(3); }, WorkPriority::Background);
    assert(warmup);
    assert(!worker.QueueWork([] { assert(false); }, WorkPriority::Background));
    worker.QueueWork([&] { order.push_back(1); });
    worker.PromoteWork(warmup);
    worker.QueueWork([&] { order.push_back(4); });
    assert(worker.QueueWork([&] { order.push_back(5); }, WorkPriority::Background));
    worker.QueueWork([&] { order.push_back(6); });
    // Re-promoting a queued urgent ID must not duplicate the build.
    worker.PromoteWork(warmup);
    release.set_value();
    worker.WaitForRequests();
    assert((order == std::vector{1, 3, 4, 6, 5}));
}

void CheckWarmupBudgetAndDrain() {
    Vulkan::PipelineWarmupPolicy policy;
    Common::ThreadWorker worker{1, "Warmup test"};
    assert(!policy.AllowsBackgroundWork());
    for (int i = 0; i < 64; ++i) {
        assert(!policy.ObserveFrame(false));
        assert(!policy.AllowsBackgroundWork());
    }
    assert(policy.ObserveFrame(true) && policy.AllowsBackgroundWork());
    assert(!policy.ObserveFrame(true));

    std::promise<void> started;
    std::promise<void> release;
    auto ready = started.get_future();
    auto gate = release.get_future();
    auto owner = std::make_unique<int>(27);
    auto* const captured = owner.get();
    bool urgent_completed = false;
    assert(worker.QueueWork([&] {
        started.set_value();
        gate.wait();
        assert(*captured == 27);
    }, WorkPriority::Background));
    assert(ready.wait_for(5s) == std::future_status::ready);
    assert(!worker.QueueWork([] { assert(false); }, WorkPriority::Background));

    policy.BeginLoading();
    assert(!policy.AllowsBackgroundWork());
    worker.QueueWork([&] {
        assert(*captured == 27);
        urgent_completed = true;
    });
    auto drained = std::async(std::launch::async, [&] { worker.WaitForRequests(); });
    assert(drained.wait_for(20ms) == std::future_status::timeout);
    release.set_value();
    assert(drained.wait_for(5s) == std::future_status::ready);
    drained.get();
    assert(urgent_completed);
    owner.reset();
    assert(!policy.ObserveFrame(false));
    assert(policy.ObserveFrame(true) && policy.AllowsBackgroundWork());
}
} // namespace

int main() {
    using namespace std::chrono_literals;
    static_assert(Vulkan::PipelineWorkerCount(true, 0) == 1);
    static_assert(Vulkan::PipelineWorkerCount(true, 2) == 1);
    static_assert(Vulkan::PipelineWorkerCount(true, 32) == 1);
    static_assert(Vulkan::PipelineWorkerCount(false, 4) == 4);

    CheckPriorityAndPromotion();
    CheckWarmupBudgetAndDrain();

    Common::ThreadWorker shaders{2, "Test shaders"};
    Common::ThreadWorker pipelines{Vulkan::PipelineWorkerCount(true, 2), "Test pipelines"};
    assert(pipelines.NumWorkers() == 1);
    for (unsigned generation = 0; generation < 8; ++generation) {
        Common::AsyncHandle shader;
        std::promise<void> release_shader;
        std::promise<void> first_job_started;
        const auto started = first_job_started.get_future();
        const auto release = release_shader.get_future().share();
        std::atomic<unsigned> completed{}, active{};
        auto cache_owner = std::make_unique<unsigned>(generation);
        const auto* const owner = cache_owner.get();
        shaders.QueueWork([&] {
            release.wait();
            shader.MarkDone();
        });
        for (unsigned job = 0; job < 128; ++job) {
            pipelines.QueueWork([&, owner, generation, job] {
                if (job == 0) first_job_started.set_value();
                shader.WaitDone();
                // No two compiler calls overlap; the captured owner remains
                // alive through the last queued job, including restore reloads.
                assert(active.fetch_add(1) == 0);
                assert(*owner == generation);
                std::this_thread::yield();
                ++completed;
                assert(active.fetch_sub(1) == 1);
            });
        }
        assert(started.wait_for(5s) == std::future_status::ready);
        auto drained = std::async(std::launch::async, [&] { pipelines.WaitForRequests(); });
        // The queue may be non-empty or its first job may be running. A drain
        // must wait for both, even while that job awaits shader completion.
        assert(drained.wait_for(20ms) == std::future_status::timeout);
        release_shader.set_value();
        shaders.WaitForRequests();
        assert(drained.wait_for(5s) == std::future_status::ready);
        drained.get();
        assert(completed == 128 && active == 0);
        cache_owner.reset(); // safe to destroy/recreate only after the drain
    }
    std::cout << "PASS: single MoltenVK compiler, shader readiness, complete worker drains and owner reloads\n";
    std::cout << "PASS: urgent promotion, one background build, zero startup prewarm, and restore drain\n";
}

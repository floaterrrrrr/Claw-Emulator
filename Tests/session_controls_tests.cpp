// SPDX-License-Identifier: GPL-3.0-or-later
#include "SessionControls.hpp"
#include <cassert>
#include <iostream>

// GPU and compression are deliberately outside this state-machine test. The
// production SessionControls method and AsyncStateOperation run unchanged.
namespace Settings {
template <typename T> struct Setting {
    T value{};
    T GetValue() const { return value; }
    void SetValue(T next) { value = next; }
};
struct { Setting<double> frame_limit; Setting<bool> enable_realtime_audio, use_vsync; } values;
}
namespace Core {
struct StateSnapshot { std::string bytes; };
inline std::atomic<int> reads{}, writes{};
inline bool fail_read{};
std::string ReadStateSnapshot(const std::string& path, unsigned long long title) {
    assert(path == "slot-1" && title == 42);
    ++reads;
    if (fail_read) throw std::runtime_error("bad archive");
    return "restored";
}
void WriteStateSnapshot(StateSnapshot snapshot, const std::string& path) {
    assert(snapshot.bytes == "captured" && path == "slot-1");
    ++writes;
}
class System {
    struct KernelState {
        bool pending{};
        bool AreAsyncOperationsPending() const { return pending; }
    } kernel;
public:
    bool powered{true}, fail_apply{};
    std::atomic<int> captures{}, applies{};
    auto& Kernel() { return kernel; }
    bool IsPoweredOn() const { return powered; }
    std::string StatePath(unsigned slot) const { assert(slot == 1); return "slot-1"; }
    unsigned long long StateTitle() const { return 42; }
    StateSnapshot CaptureStateSnapshot() {
        assert(!kernel.pending);
        ++captures;
        return {"captured"};
    }
    void ApplyStateSnapshot(std::string bytes) {
        assert(!kernel.pending && bytes == "restored");
        ++applies;
        if (fail_apply) throw std::runtime_error("apply failed");
    }
};
}

using namespace Claw;
static void finish(SessionControls& controls, Core::System& core, bool paused) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (controls.states.status() == StateStatus::Pending) {
        controls.process(core, paused);
        if (std::chrono::steady_clock::now() >= deadline)
            throw std::runtime_error("State operation never crossed the safe boundary");
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}

int main() {
    Core::System core;
    SessionControls controls;
    for (bool paused : {false, true}) {
        assert(controls.states.request(false, 1));
        finish(controls, core, paused);
        assert(controls.states.status() == StateStatus::Saved);
        assert(controls.states.request(true, 1));
        finish(controls, core, paused);
        assert(controls.states.status() == StateStatus::Restored);
    }
    assert(core.captures == 2 && core.applies == 2 && Core::reads == 2 && Core::writes == 2);

    // A ready worker must wait while the guest still owns asynchronous state.
    std::mutex mutex;
    std::condition_variable ready;
    bool notified{};
    controls.wake = [&] { std::lock_guard lock(mutex); notified = true; ready.notify_all(); };
    assert(controls.states.request(false, 1));
    controls.process(core, false);
    {
        std::unique_lock lock(mutex);
        assert(ready.wait_for(lock, std::chrono::seconds(2), [&] { return notified; }));
    }
    core.Kernel().pending = true;
    controls.process(core, false);
    assert(controls.states.status() == StateStatus::Pending && core.captures == 2);
    core.Kernel().pending = false;
    finish(controls, core, false);
    assert(core.captures == 3 && Core::writes == 3);
    controls.joinStateWorker();
    controls.wake = {};

    Core::fail_read = true;
    assert(controls.states.request(true, 1));
    finish(controls, core, true);
    assert(controls.states.status() == StateStatus::Failed && core.applies == 2);
    assert(controls.states.error() == "bad archive");
    Core::fail_read = false;

    core.fail_apply = true;
    assert(controls.states.request(true, 1));
    bool rejected = false;
    try { finish(controls, core, true); }
    catch (const std::runtime_error& error) {
        rejected = std::string(error.what()).find("could not be safely restored") != std::string::npos;
    }
    assert(rejected && controls.states.status() == StateStatus::Failed);
    core.fail_apply = false;

    core.Kernel().pending = true;
    assert(controls.states.request(false, 1));
    finish(controls, core, true);
    assert(controls.states.status() == StateStatus::Failed && core.captures == 3);
    core.Kernel().pending = false;
    core.powered = false;
    assert(controls.states.request(false, 1));
    finish(controls, core, true);
    assert(controls.states.error() == "The game is no longer running.");
    std::cout << "PASS: production session save/restore boundaries, pending guest work, failures and shutdown\n";
}

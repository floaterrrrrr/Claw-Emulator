// SPDX-License-Identifier: GPL-3.0-or-later
#include "../Native/ClawCore.h"
#include "../Native/SessionGate.hpp"
#include "../Native/SessionControls.hpp"
#include <array>
#include <atomic>
#include <cassert>
#include <chrono>
#include <cmath>
#include <future>
#include <iostream>
#include <limits>
#include <thread>
using namespace std::chrono_literals;

int main() {
    // Touch corners, center, 2x scaling, and dragged-outside positions.
    auto point = Claw3DSMapTouch(150, 100, 300, 200, 320, 240);
    assert(std::abs(point.x - 159.5f) < 0.001f);
    assert(std::abs(point.y - 119.5f) < 0.001f);
    point = Claw3DSMapTouch(300, 200, 300, 200, 640, 480);
    assert(point.x == 639 && point.y == 479);
    point = Claw3DSMapTouch(-5, 240, 300, 200, 320, 240);
    assert(point.x == 0 && point.y == 239);
    point = Claw3DSMapTouch(0, 0, 0, 200, 320, 240);
    assert(point.x == -1 && point.y == -1);
    point = Claw3DSMapTouch(std::numeric_limits<float>::quiet_NaN(), 0, 300, 200, 320, 240);
    assert(point.x == -1 && point.y == -1);

    SessionGate gate;
    gate.begin();
    gate.pause(true);
    std::promise<void> entered;
    auto resumed = std::async(std::launch::async, [&] {
        entered.set_value();
        return gate.waitUntilRunnable();
    });
    entered.get_future().wait();
    // A paused waiter remains blocked; it must not return and spin RunLoop.
    assert(resumed.wait_for(30ms) == std::future_status::timeout);
    gate.pause(false);
    assert(resumed.wait_for(1s) == std::future_status::ready);
    assert(resumed.get());

    // Stop wakes a paused thread, including repeated start/pause/stop sessions.
    for (int i = 0; i < 100; ++i) {
        gate.begin();
        gate.pause(true);
        auto stopped = std::async(std::launch::async, [&] { return gate.waitUntilRunnable(); });
        gate.stop();
        assert(stopped.wait_for(1s) == std::future_status::ready);
        assert(!stopped.get());
    }
    // A utility command wakes a paused session once without advancing the game.
    gate.begin();
    gate.pause(true);
    auto command = std::async(std::launch::async, [&] { return gate.waitForWork(); });
    assert(command.wait_for(30ms) == std::future_status::timeout);
    gate.notifyWork();
    assert(command.wait_for(1s) == std::future_status::ready);
    assert(command.get() == SessionGate::Wake::Command);
    assert(gate.isPaused());
    auto idle = std::async(std::launch::async, [&] { return gate.waitForWork(); });
    assert(idle.wait_for(30ms) == std::future_status::timeout);
    gate.stop();
    assert(idle.wait_for(1s) == std::future_status::ready);
    assert(idle.get() == SessionGate::Wake::Stopped);

    // Concurrent taps cannot queue conflicting saves/restores, even after dequeue.
    Claw::StateRequestQueue requests;
    std::atomic<int> accepted{0};
    std::array<std::thread, 4> contenders;
    for (auto& thread : contenders) {
        thread = std::thread([&] { if (requests.request(false, 1)) ++accepted; });
    }
    for (auto& thread : contenders) thread.join();
    assert(accepted == 1);
    const auto state = requests.take();
    assert(state && !state->restore && state->slot == 1);
    assert(!requests.request(true, 1));
    assert(requests.status() == Claw::StateStatus::Pending);
    requests.complete(Claw::StateStatus::Saved);
    assert(!requests.request(true, 0));
    assert(!requests.request(true, 12));
    assert(requests.request(true, 1));
    requests.cancel();
    assert(!requests.take());
    assert(requests.status() == Claw::StateStatus::Failed && !requests.error().empty());
    requests.reset();
    assert(requests.status() == Claw::StateStatus::Idle && requests.error().empty());
    std::cout << "PASS: touch mapping, pause/resume, paused commands, concurrent state requests, and 100 paused shutdown cycles\n";
}

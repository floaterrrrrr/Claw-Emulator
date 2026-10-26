// SPDX-License-Identifier: GPL-3.0-or-later
#include "Retro/RetroRuntime.hpp"
#include "audio_core/mobile_audio_buffer.h"
#include <cassert>
#include <filesystem>
#include <future>
#include <iostream>
#include <memory>
#include <vector>

using namespace ClawRetro;
using namespace std::chrono_literals;

static void audioLatency() {
    AudioCore::MobilePCM16Buffer original;
    auto gba = std::make_unique<AudioCore::MobilePCM16Buffer>(AudioTargetFrames(1, original.TargetFrames()));
    assert(original.TargetFrames() == 6144 && gba->TargetFrames() == 1024);
    assert(AudioTargetFrames(2, original.TargetFrames()) == original.TargetFrames());
    assert(AudioTargetFrames(3, original.TargetFrames()) == original.TargetFrames());
    std::vector<std::int16_t> input(6144 * 2, 1000), output(4096 * 2, -1);
    assert(gba->Push({input.data(), 1023 * 2}) == 1023);
    assert(gba->Read({output.data(), 256 * 2}) == 0);
    assert(gba->Underruns() == 0); // Initial priming is not an underrun.
    assert(gba->Push({input.data(), 2}) == 1);
    assert(gba->Read({output.data(), 256 * 2}) == 256);
    assert(output[0] > 0 && output[0] < 1000); // Fade-in survives the shorter target.
    assert(gba->Read(output) == 768);
    assert(gba->Underruns() == 1 && output[3000 * 2] == 0);
    gba->Discard();
    assert(gba->BufferedFrames() == 0);
    assert(gba->Push({input.data(), 1024 * 2}) == 1024);
    assert(gba->Read({output.data(), 256 * 2}) == 256);
    gba->Discard();
    assert(gba->Push({input.data(), 1024 * 2}) == 1024);
    assert(gba->Read({output.data(), 256 * 2}, 2048) == 0);
    assert(gba->Push({input.data(), 1024 * 2}) == 1024);
    assert(gba->Read({output.data(), 256 * 2}, 2048) == 256);
    assert(original.Push({input.data(), 6143 * 2}) == 6143);
    assert(original.Read({output.data(), 256 * 2}) == 0);
    assert(original.Push({input.data(), 2}) == 1);
    assert(original.Read({output.data(), 256 * 2}) == 256);
    AudioLatencyBudget budget;
    assert(budget.target(256) == 1024 && budget.target(1024) == 2048);
    budget.observe(256, true);
    assert(budget.target(256) == 1280);
    for (int i = 0; i < 48000 * 30 / 256 + 1; ++i) budget.observe(256, false);
    assert(budget.target(256) == 1024);
    for (int i = 0; i < 1000; ++i) budget.observe(256, true);
    assert(budget.target(256) == 3072 && budget.target(8192) == 16384);
    std::cout << "PASS: mGBA 21.3 ms priming, hardware-slice/underrun adaptation, fade/recovery and flush; original 128 ms default unchanged\n";
}

static void pacing() {
    assert(DisplayTargetHz(false, 0) == 60 && DisplayTargetHz(false, 2) == 60);
    assert(DisplayTargetHz(false, 3) == 30 && DisplayTargetHz(true, 0) == 30);
    PresentationStatistics stats;
    constexpr double rate = 59.7275005696;
    for (int frame = 0; frame <= 120; ++frame) stats.record(10 + frame / rate, 1);
    auto sample = stats.sample();
    assert(sample.frames == 121 && std::abs(sample.fps - rate) < 0.001);
    assert(std::abs(sample.worstIntervalMS - 1000 / rate) < 0.001);
    assert(stats.sample(13).fps == 0 && stats.sample().fps > 59);
    stats.record(1, 1); stats.record(NAN, 1); stats.record(INFINITY, 1);
    assert(stats.sample().frames == 121);
    stats.record(30, 1); // Actual display hitch is reported even if the core was at 60 FPS.
    assert(stats.sample().worstIntervalMS > 1000);
    stats.record(100, 2); stats.record(100 + 1 / rate, 2);
    assert(stats.sample().frames == 2 && stats.sample().worstIntervalMS < 17);
    std::cout << "PASS: display callback targets, thermal cap, actual presentation timing and epoch reset\n";
}

static void frameEvents(const char* library, const char* directory) {
    std::filesystem::create_directories(directory);
    Runtime core({1, 0xC100000000000123ULL, "fixture.gba", directory, library, "frame-ready-test"});
    core.start();
    std::atomic_bool cancelled{false};
    auto first = std::async(std::launch::async, [&] { return core.waitForFrame(0, cancelled); });
    assert(first.wait_for(20ms) == std::future_status::timeout);
    core.pause(false);
    assert(first.wait_for(2s) == std::future_status::ready);
    assert(first.get()->sequence > 0);
    const auto initialEpoch = core.epoch();
    core.button(RETRO_DEVICE_ID_JOYPAD_B, true);
    const auto rateDeadline = std::chrono::steady_clock::now() + 1s;
    while (core.sampleRate() != 96000 && std::chrono::steady_clock::now() < rateDeadline)
        std::this_thread::sleep_for(1ms);
    std::cout << "Mid-game source clock: " << core.sampleRate() << " Hz (expected 96000)\n";
    assert(core.sampleRate() == 96000 && core.epoch() > initialEpoch);
    core.button(RETRO_DEVICE_ID_JOYPAD_B, false);
    while (core.sampleRate() != 48000 && std::chrono::steady_clock::now() < rateDeadline + 1s)
        std::this_thread::sleep_for(1ms);
    assert(core.sampleRate() == 48000);
    core.button(RETRO_DEVICE_ID_JOYPAD_Y, true);
    while (core.sampleRate() != 262144 && std::chrono::steady_clock::now() < rateDeadline + 2s)
        std::this_thread::sleep_for(1ms);
    assert(core.sampleRate() == 262144);
    const auto highRateEpoch = core.epoch();
    core.button(RETRO_DEVICE_ID_JOYPAD_X, true);
    std::this_thread::sleep_for(25ms);
    assert(core.sampleRate() == 262144 && core.epoch() == highRateEpoch);
    core.button(RETRO_DEVICE_ID_JOYPAD_X, false);
    core.button(RETRO_DEVICE_ID_JOYPAD_Y, false);
    core.setSpeed(4);
    std::this_thread::sleep_for(40ms);
    core.pause(true);
    std::this_thread::sleep_for(20ms); // Let a frame already in retro_run finish.
    const auto latest = core.frame();
    assert(latest && latest->sequence > 1);
    assert(core.waitForFrame(0, cancelled)->sequence == latest->sequence); // Latest only; no backlog.
    auto pending = std::async(std::launch::async, [&] { return core.waitForFrame(latest->sequence, cancelled); });
    assert(pending.wait_for(20ms) == std::future_status::timeout);
    cancelled.store(true); core.wakeFrameWaiters();
    assert(pending.wait_for(2s) == std::future_status::ready && !pending.get());
    // Cancellation may arrive before the waiter has even acquired its mutex.
    for (int iteration = 0; iteration < 32; ++iteration) {
        cancelled.store(false);
        auto early = std::async(std::launch::async, [&] { return core.waitForFrame(latest->sequence, cancelled); });
        cancelled.store(true); core.wakeFrameWaiters();
        assert(early.wait_for(2s) == std::future_status::ready && !early.get());
    }
    cancelled.store(false);
    auto stopping = std::async(std::launch::async, [&] { return core.waitForFrame(latest->sequence, cancelled); });
    core.requestStop();
    assert(stopping.wait_for(2s) == std::future_status::ready && !stopping.get());
    core.stop();
    std::cout << "PASS: dynamic source audio clocks, production frame-ready wakeups, latest-frame coalescing, paused waits, cancellation races and joined stop\n";
}

int main(int argc, char** argv) {
    assert(argc == 3);
    audioLatency(); pacing(); frameEvents(argv[1], argv[2]);
}

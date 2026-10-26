// SPDX-License-Identifier: GPL-3.0-or-later
#include "Retro/RetroRuntime.hpp"
#include <cassert>
#include <cstdlib>
#include <chrono>
#include <thread>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
namespace fs = std::filesystem;
using Bytes = std::vector<unsigned char>;
void write(const fs::path& path, const Bytes& bytes) {
    std::ofstream file(path, std::ios::binary);
    file.write(reinterpret_cast<const char*>(bytes.data()), bytes.size());
}
Bytes read(const fs::path& path) {
    std::ifstream file(path, std::ios::binary);
    return Bytes(std::istreambuf_iterator<char>(file), {});
}
int main(int argc, char** argv) {
    assert(argc == 3);
    const fs::path root = argv[2];
    const auto directory = root / "BatterySaves/C100000000000123";
    fs::create_directories(directory);
    const auto battery = directory / "battery.srm", rtc = directory / "clock.rtc";
    const Bytes oldRAM(12345, 0x42), oldRTC(16, 0x73);
    auto config = [&] { return ClawRetro::Configuration{1, 0xC100000000000123ULL,
        "fixture.gba", root.string(), argv[1], "failure-test"}; };
    auto failedStart = [&] {
        bool failed = false;
        { ClawRetro::Runtime core(config());
          try { core.start(); } catch (const std::exception&) { failed = true; } }
        assert(failed);
    };
    write(battery, oldRAM); write(rtc, oldRTC);
    failedStart(); // Unexpected battery size, destructor must only unload.
    assert(read(battery) == oldRAM && read(rtc) == oldRTC);
    setenv("CLAW_TEST_INVALID_AV", "1", 1);
    failedStart(); // Validation fails before restoring either battery part.
    unsetenv("CLAW_TEST_INVALID_AV");
    assert(read(battery) == oldRAM && read(rtc) == oldRTC);
    const Bytes validRAM(32768, 0x56), badRTC(17, 0x19);
    write(battery, validRAM); write(rtc, badRTC);
    failedStart(); // RAM restored, later RTC validation fails: preserve both.
    assert(read(battery) == validRAM && read(rtc) == badRTC);
    write(rtc, oldRTC);
    { ClawRetro::Runtime core(config()); core.start(); core.stop(); }
    const auto restored = read(battery);
    assert(restored.size() == 131072);
    assert(std::equal(validRAM.begin(), validRAM.end(), restored.begin()));
    assert(restored.back() == 0xFF && read(rtc) == oldRTC);
    // A core that rejects a state after mutating RAM must stop without saving
    // that partially restored memory over the user's cartridge save.
    write(battery, validRAM); write(rtc, oldRTC);
    {
        ClawRetro::Runtime core(config()); core.start();
        auto waitForState = [&] {
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
            while (core.stateStatus() == 1 && std::chrono::steady_clock::now() < deadline)
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            assert(core.stateStatus() != 1);
        };
        assert(core.state(1, false)); waitForState(); assert(core.stateStatus() == 2);
        assert(core.state(1, true)); waitForState(); assert(core.stateStatus() == -1);
        core.stop();
    }
    assert(read(battery) == validRAM && read(rtc) == oldRTC);
    std::cout << "PASS: failed size/AV/RTC startup and partial restore preserve battery bytes; valid startup persists; option support probes\n";
}

// SPDX-License-Identifier: GPL-3.0-or-later
#include "Retro/RetroRuntime.hpp"
#include <cassert>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <thread>
using namespace ClawRetro;
namespace fs = std::filesystem;
template<class F> void until(F condition, Runtime& core) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(12);
    while (!condition() && core.running() && std::chrono::steady_clock::now() < deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    if (!condition()) throw std::runtime_error("Timed out: " + core.error());
}
int main(int argc, char** argv) {
    try {
        if (argc != 7) throw std::runtime_error("Expected core, library, ROM, data root, width and height");
        const int type = std::stoi(argv[1]); const auto root = fs::path(argv[4]);
        fs::create_directories(root);
        Runtime core({type, 0xC100000000000123ULL, argv[3], root.string(), argv[2], "core-test-revision"});
        core.start(); assert(core.running() && core.paused());
        core.pause(false);
        until([&] { const auto f = core.frame(); return f && f->sequence > 20; }, core);
        if (!core.error().empty()) throw std::runtime_error("Unexpected startup error: " + core.error());
        auto frame = core.frame();
        assert(frame->width == unsigned(std::stoi(argv[5])) && frame->height == unsigned(std::stoi(argv[6])));
        assert(frame->bgra.size() == frame->width * frame->height);
        for (auto pixel : frame->bgra) assert((pixel >> 24) == 255);
        if (type == 3) assert((frame->bgra[100] & 0xFFFFFF) >= 0xF00000 && (frame->bgra[100] & 0xFFFF) == 0);
        if (fs::path(argv[3]).extension() == ".gba") {
            const auto red = frame->bgra[100]; assert((red & 0xFFFFFF) == 0xFF0000);
            core.button(RETRO_DEVICE_ID_JOYPAD_A, true);
            until([&] { return (core.frame()->bgra[100] & 0xFFFFFF) == 0xFF; }, core);
            core.button(RETRO_DEVICE_ID_JOYPAD_A, false);
            assert(core.sampleRate() == 32768);
            core.button(RETRO_DEVICE_ID_JOYPAD_B, true);
            until([&] { return core.sampleRate() == 65536; }, core);
            core.button(RETRO_DEVICE_ID_JOYPAD_B, false);
            until([&] { return core.sampleRate() == 32768; }, core);
        }
        core.pause(true);
        std::int16_t audio[2048]{};
        assert(core.audio.pop(audio, 1024) > 0);
        assert(core.state(1, false)); assert(!core.state(2, false));
        until([&] { return core.stateStatus() != 1; }, core);
        if (core.stateStatus() != 2) throw std::runtime_error(core.error());
        const auto path = root / "save_states/C100000000000123.01.cst";
        assert(fs::exists(path) && fs::file_size(path) > 256);
        assert(fs::exists(path.string() + ".png"));
        if (fs::path(argv[3]).extension() == ".gba") {
            core.button(RETRO_DEVICE_ID_JOYPAD_B, true); core.pause(false);
            until([&] { return core.sampleRate() == 65536; }, core);
            core.pause(true);
        }
        assert(core.state(1, true)); until([&] { return core.stateStatus() != 1; }, core);
        if (core.stateStatus() != 3) throw std::runtime_error(core.error());
        if (fs::path(argv[3]).extension() == ".gba") assert(core.sampleRate() == 32768);
        const auto validState = path.string() + ".valid";
        fs::copy_file(path, validState, fs::copy_options::overwrite_existing);
        { std::fstream f(path, std::ios::binary | std::ios::in | std::ios::out); f.seekg(24); char corrupt; f.read(&corrupt, 1); corrupt ^= 0x80; f.seekp(24); f.write(&corrupt, 1); }
        assert(core.state(1, true)); until([&] { return core.stateStatus() != 1; }, core);
        assert(core.stateStatus() == -1 && core.running());
        for (int speed : {2, 4, 1}) { core.setSpeed(speed); assert(core.speed() == speed); }
        core.stop(); assert(!core.running());
        fs::copy_file(validState, path, fs::copy_options::overwrite_existing);
        const auto extension = fs::path(argv[3]).extension();
        if (extension == ".gb" || extension == ".gbc" || extension == ".gba") {
            const auto battery = root / "BatterySaves/C100000000000123/battery.srm";
            assert(fs::file_size(battery) == (extension == ".gba" ? 32768 : 8192));
            std::ifstream file(battery, std::ios::binary); char value; file.read(&value, 1); assert(value == 0x42);
        }
        // A second session in this process must start cleanly after dlclose,
        // retain battery memory, and reject a state from an incompatible build.
        Runtime reopened({type, 0xC100000000000123ULL, argv[3], root.string(), argv[2], "different-core-revision"});
        reopened.start(); reopened.pause(false);
        until([&] { const auto f = reopened.frame(); return f && f->sequence > 20; }, reopened);
        assert(reopened.state(1, true)); until([&] { return reopened.stateStatus() != 1; }, reopened);
        assert(reopened.stateStatus() == -1 && reopened.running());
        assert(reopened.error().find("different core version") != std::string::npos);
        reopened.stop();
        if (extension == ".gb" || extension == ".gbc" || extension == ".gba") {
            std::ifstream file(root / "BatterySaves/C100000000000123/battery.srm", std::ios::binary);
            char value; file.read(&value, 1); assert(value == 0x43);
        }
        std::cout << "PASS: real core " << type << ' ' << fs::path(argv[3]).extension()
                  << " video/audio, input, snapshot/preview, restore, corrupt/version rejection, speed modes, joined stop/reopen and battery retention\n";
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}

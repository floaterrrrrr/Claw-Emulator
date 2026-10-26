// SPDX-License-Identifier: GPL-3.0-or-later
#include "SessionCleanup.hpp"
#include "audio_core/pcm_conversion.h"
#include "common/async_handle.h"
#include <array>
#include <cassert>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <thread>

int main(int argc, char** argv) {
    assert(argc == 2);
    namespace fs = std::filesystem;
    const fs::path root = argv[1], sys = root / "sysdata", states = root / "save_states";
    fs::create_directories(sys / "nested");
    fs::create_directories(states);
    const auto write = [](const fs::path& path) { std::ofstream(path) << "preserve contents"; };
    for (const char* name : {"old.lock", "old.tmp", "state.bin.partial", "state.cst.partial",
                             "keys.txt", "seeddb.bin", "config.bin", "completed.cst"}) write(sys / name);
    write(sys / "nested" / "keep.tmp");
    fs::create_directories(sys / "directory.tmp");
    write(root / "outside.lock");
    fs::create_symlink(root / "outside.lock", sys / "linked.lock");
    write(states / "0004000001234500.01.cst.tmp");
    write(states / "0004000001234500.01.cst");
    write(states / "unrelated.tmp");
    assert(Claw::CleanupSessionArtifacts(sys, states) == 5);
    assert(Claw::CleanupSessionArtifacts(sys, states) == 0);
    for (const char* name : {"keys.txt", "seeddb.bin", "config.bin", "completed.cst"}) assert(fs::exists(sys / name));
    assert(fs::exists(sys / "nested" / "keep.tmp"));
    assert(fs::is_directory(sys / "directory.tmp"));
    assert(fs::is_symlink(sys / "linked.lock") && fs::exists(root / "outside.lock"));
    assert(fs::exists(states / "0004000001234500.01.cst") && fs::exists(states / "unrelated.tmp"));
    fs::create_directory_symlink(sys, root / "linked-root");
    write(sys / "keep-on-linked-root.tmp");
    assert(Claw::CleanupSessionArtifacts(root / "linked-root", root / "missing") == 0);
    assert(fs::exists(sys / "keep-on-linked-root.tmp"));

    constexpr std::array<s16, 6> pcm{-32768, -1, 0, 1, 12345, 32767};
    std::array<float, 7> converted{};
    converted.back() = 9;
    AudioCore::PCM16ToFloat(pcm, {converted.data(), 6});
    assert(converted[0] == -1 && converted[5] < 1 && converted.back() == 9);
    for (std::size_t i = 0; i < pcm.size(); ++i) assert(AudioCore::FloatToPCM16(converted[i]) == pcm[i]);
    assert(AudioCore::FloatToPCM16(10) == 32767 && AudioCore::FloatToPCM16(-10) == -32768);
    assert(AudioCore::FloatToPCM16(std::numeric_limits<float>::quiet_NaN()) == 0);
    assert(AudioCore::FloatToPCM16(std::numeric_limits<float>::infinity()) == 0);
    AudioCore::PCM16ToFloat(pcm, {});

    // Test both completion paths with data published by a different thread.
    for (int i = 1; i <= 500; ++i) {
        Common::AsyncHandle task;
        int published = 0;
        std::thread producer([&] { published = i; task.MarkDone(); });
        if (i % 2) task.WaitDone();
        else while (!task.IsDone()) std::this_thread::yield();
        assert(published == i);
        producer.join();
    }
    std::cout << "PASS: teardown cleanup preserves saves/keys/binaries/symlinks; PCM conversion bounds; 500 async publications\n";
}

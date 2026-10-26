// SPDX-License-Identifier: GPL-3.0-or-later
#include <cassert>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include "common/archives.h"
#include "common/file_util.h"

// File utilities use this only before aborting an internal assertion. The
// standalone filesystem test does not start the emulator's logging thread.
namespace Common::Log { void Stop() {} }

static std::string capture(std::string path, bool legacy) {
    std::ostringstream stream(std::ios::binary);
    {
        oarchive archive(stream);
        const unsigned before = 17, after = 42;
        archive & before;
        if (legacy) archive & path;
        else FileUtil::SerializeArchivePath(archive, path);
        archive & after;
    }
    return stream.str();
}

static std::string restore(const std::string& bytes, bool legacy = false) {
    std::istringstream stream(bytes, std::ios::binary);
    iarchive archive(stream);
    unsigned before = 0, after = 0;
    std::string path;
    archive & before;
    if (legacy) archive & path;
    else FileUtil::SerializeArchivePath(archive, path);
    archive & after;
    assert(before == 17 && after == 42); // original binary field order is intact
    return path;
}

int main(int argc, char** argv) {
    assert(argc == 2);
    namespace fs = std::filesystem;
    const fs::path root(argv[1]);
    const std::string oldRoot = (root / "old/Documents/EmulationData").string() + "/";
    const std::string newRoot = (root / "new/Documents/EmulationData").string() + "/";
    const std::string title = "sdmc/Nintendo 3DS/id0/id1/title/00040000/000edf00/data/";
    const std::string mount = title + "00000001/";
    fs::create_directories(oldRoot + mount);
    std::ofstream(oldRoot + mount + "save.bin") << "existing progress";
    std::ofstream(oldRoot + title + "00000001.metadata") << "format metadata!";
    FileUtil::SetUserPath(oldRoot);
    const auto legacy = capture(oldRoot + mount, true);
    const auto portable = capture(oldRoot + mount, false);
    assert(portable.find(oldRoot) == std::string::npos);
    assert(restore(portable) == oldRoot + mount);
    assert(restore(legacy) == oldRoot + mount);

    // Move the data exactly as a sandbox migration would. With the previous
    // raw-string loader the state still points at a nonexistent save archive.
    fs::rename(root / "old", root / "new");
    FileUtil::SetUserPath(newRoot);
    assert(!fs::exists(restore(legacy, true)));
    for (const auto& bytes : {legacy, portable}) {
        const auto current = restore(bytes);
        assert(current == newRoot + mount && fs::is_directory(current));
        FileUtil::IOFile file(current + "save.bin", "rb");
        char contents[17]{};
        assert(file.IsOpen() && file.ReadBytes(contents, sizeof(contents)) == sizeof(contents));
        assert(std::string(contents, sizeof(contents)) == "existing progress");
        assert(fs::file_size(newRoot + title + "00000001.metadata") == 16);
    }

    // Both already-open archives and the factories that reopen them must
    // relocate. Include normal saves, extdata, SD and NAND/system-save roots.
    for (const auto& suffix : {"sdmc/", "sdmc", "nand/", "nand",
                              "sdmc/Nintendo 3DS/id0/id1/extdata/",
                              "nand/data/id0/sysdata/"}) {
        assert(restore(capture(oldRoot + suffix, true)) == newRoot + suffix);
    }
    assert(FileUtil::RestoreArchivePath("%CITRA_USER_DIR%" + mount) == newRoot + mount);
    assert(FileUtil::RestoreArchivePath("%CITRA_USER_SDMC%Nintendo 3DS/") ==
           newRoot + "sdmc/Nintendo 3DS/");
    assert(FileUtil::RestoreArchivePath("%CITRA_USER_NAND%data/") == newRoot + "nand/data/");
    for (const std::string unchanged : {"", "/custom/sdmc/", "relative/Documents/EmulationData/sdmc/",
                                       "/old/Documents/EmulationData/sdmc-other/",
                                       "/old/Documents/EmulationData/sdmc/../other/",
                                       "/old/Documents/EmulationData/roms/"}) {
        assert(FileUtil::RestoreArchivePath(unchanged) == unchanged);
        assert(capture(unchanged, true) == capture(unchanged, false));
        assert(restore(capture(unchanged, true)) == unchanged);
    }
    // A missing save stays missing. Restoration must never format or invent it.
    const auto missing = restore(capture(oldRoot + "sdmc/missing/", true));
    assert(missing == newRoot + "sdmc/missing/" && !fs::exists(missing));
    std::cout << "PASS: legacy and portable state paths reopen preserved saves after a sandbox move; "
                 "binary layout, SD/NAND roots, unrelated paths and missing saves\n";
}

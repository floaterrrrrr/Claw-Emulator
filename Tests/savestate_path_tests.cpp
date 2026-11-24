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

static std::string capture_open_file(const std::string& path) {
    FileUtil::IOFile file(path, "r+b");
    assert(file.IsOpen() && file.Seek(9, SEEK_SET));
    std::ostringstream stream(std::ios::binary);
    {
        oarchive archive(stream);
        archive & file;
    }
    return stream.str();
}

int main(int argc, char** argv) {
    assert(argc == 2);
    namespace fs = std::filesystem;
    const fs::path root(argv[1]);
    const auto containers = root / "Containers/Data/Application";
    const auto old_container = containers / "043CB7FD-A2E7-4857-9EC4-204EC9825923";
    const auto new_container = containers / "F3C4D7AE-B68F-4266-9F3B-BD52DF96CCD1";
    const std::string oldRoot = (old_container / "Documents/EmulationData").generic_string() + "/";
    const std::string newRoot = (new_container / "Documents/EmulationData").generic_string() + "/";
    const std::string title = "sdmc/Nintendo 3DS/id0/id1/title/00040000/000edf00/data/";
    const std::string mount = title + "00000001/";
    fs::create_directories(oldRoot + mount);
    std::ofstream(oldRoot + mount + "save.bin") << "existing progress";
    std::ofstream(oldRoot + title + "00000001.metadata") << "format metadata!";
    const auto old_filename = oldRoot + mount + "save.bin";
    // A non-container root leaves the absolute filename in the real IOFile
    // serializer, producing the same filename field as a legacy save state.
    FileUtil::SetUserPath((root / "other").generic_string() + "/");
    const auto legacy_file = capture_open_file(old_filename);
    assert(legacy_file.find(old_filename) != std::string::npos);
    FileUtil::SetUserPath(oldRoot);
    const auto legacy = capture(oldRoot + mount, true);
    const auto portable = capture(oldRoot + mount, false);
    const auto portable_file = capture_open_file(old_filename);
    assert(portable.find(oldRoot) == std::string::npos);
    assert(portable_file.find("%CITRA_USER_DIR%" + mount + "save.bin") != std::string::npos);
    assert(restore(portable) == oldRoot + mount);
    assert(restore(legacy) == oldRoot + mount);

    // Move the data exactly as a sandbox migration would. With the previous
    // raw-string loader the state still points at a nonexistent save archive.
    fs::rename(old_container, new_container);
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

    const auto new_filename = newRoot + mount + "save.bin";
    for (const auto& bytes : {legacy_file, portable_file}) {
        std::istringstream stream(bytes, std::ios::binary);
        iarchive archive(stream);
        FileUtil::IOFile file;
        archive & file;
        assert(file.Filename() == new_filename && file.IsOpen() && file.Tell() == 9);
        assert(file.WriteString("progress!") == 9 && file.Flush());
        std::string contents;
        assert(FileUtil::ReadFileToString(false, new_filename, contents) == 18);
        assert(contents == "existing progress!");
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
    assert(FileUtil::RestoreArchivePath("/old/Documents/EmulationData/sdmc/") == newRoot + "sdmc/");
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
    std::cout << "PASS: legacy and portable archive paths and open save files after a sandbox move; "
                 "binary layout, writable handles, SD/NAND roots and missing saves\n";
}

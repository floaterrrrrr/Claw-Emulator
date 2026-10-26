// SPDX-License-Identifier: GPL-3.0-or-later
#include <cassert>
#include <filesystem>
#include <fstream>
#include <iostream>
#include "common/common_paths.h"
#include "common/file_util.h"

int main(int argc, char** argv) {
    assert(argc == 2);
    const std::filesystem::path root(argv[1]);
    const std::string first = (root / "old-container/EmulationData").string() + "/";
    const std::string second = (root / "new-container/EmulationData").string() + "/";
    std::filesystem::create_directories(first + "sysdata");
    std::filesystem::create_directories(second + "sysdata");
    std::ofstream(first + "sysdata/keys.txt") << "old";
    std::ofstream(second + "sysdata/keys.txt") << "new";
    FileUtil::SetUserPath(first);
    assert(FileUtil::GetUserPath(FileUtil::UserPath::SysDataDir) == first + SYSDATA_DIR "/");
    FileUtil::SetUserPath(second);
    assert(FileUtil::GetUserPath(FileUtil::UserPath::UserDir) == second);
    for (const auto& [kind, directory] : {
             std::pair{FileUtil::UserPath::SysDataDir, SYSDATA_DIR "/"},
             std::pair{FileUtil::UserPath::NANDDir, "nand/"},
             std::pair{FileUtil::UserPath::SDMCDir, "sdmc/"},
             std::pair{FileUtil::UserPath::ConfigDir, "config/"},
             std::pair{FileUtil::UserPath::CacheDir, "cache/"},
             std::pair{FileUtil::UserPath::StatesDir, STATES_DIR "/"}}) {
        assert(FileUtil::GetUserPath(kind) == second + directory);
        assert(FileUtil::GetDefaultUserPath(kind) == second + directory);
    }
    // Match the mobile bridge's explicit pin of the app's existing sysdata schema.
    FileUtil::UpdateUserPath(FileUtil::UserPath::SysDataDir, second + "sysdata/");
    FileUtil::IOFile file(FileUtil::GetUserPath(FileUtil::UserPath::SysDataDir) + "keys.txt", "rb");
    char actual[3]{};
    assert(file.IsOpen() && file.ReadBytes(actual, sizeof(actual)) == sizeof(actual));
    assert(std::string(actual, sizeof(actual)) == "new");
    std::cout << "PASS: rebinding sandbox roots updates cached paths and reads the new keys.txt\n";
}

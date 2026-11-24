// SPDX-License-Identifier: GPL-3.0-or-later
#include "common/serialization/ios_container_path.h"

#include <cassert>
#include <iostream>

int main() {
    using FileUtil::StatePath::DecodeIOSPath;
    using FileUtil::StatePath::EncodeIOSPath;
    const std::string old_container =
        "/var/mobile/Containers/Data/Application/043CB7FD-A2E7-4857-9EC4-204EC9825923";
    const std::string new_container =
        "/private/var/mobile/Containers/Data/Application/f3c4d7ae-b68f-4266-9f3b-bd52df96ccd1";
    const std::string old_user_dir = old_container + "/Documents/EmulationData/";
    const std::string new_user_dir = new_container + "/Documents/EmulationData/";

    for (const std::string_view suffix : {"", "sdmc/", "nand/data/id0/sysdata/",
                                         "sdmc/Nintendo 3DS/id0/title/data/00000001/",
                                         "sdmc/Nintendo 3DS/id0/title/data/00000001/save.bin",
                                         "sdmc/Nintendo 3DS/id0/title/data/00000001.metadata",
                                         "sysdata/seeddb.bin"}) {
        const auto old_path = old_user_dir + std::string(suffix);
        const auto current_path = new_user_dir + std::string(suffix);
        const auto stored = EncodeIOSPath("/private" + old_path, old_user_dir);
        assert(stored == "%CITRA_USER_DIR%" + std::string(suffix));
        assert(DecodeIOSPath(*stored, new_user_dir) == current_path);
        assert(DecodeIOSPath(old_path, new_user_dir) == current_path);
        assert(DecodeIOSPath("/private" + old_path, new_user_dir) == current_path);
    }

    const std::string outside_user_dir = "/Library/Application Support/extra.dat";
    const auto stored = EncodeIOSPath(old_container + outside_user_dir, old_user_dir);
    assert(stored == "%CITRA_IOS_DATA_CONTAINER%" + outside_user_dir);
    assert(DecodeIOSPath(*stored, new_user_dir) == new_container + outside_user_dir);
    assert(DecodeIOSPath(old_container + outside_user_dir, new_user_dir) ==
           new_container + outside_user_dir);
    assert(DecodeIOSPath(old_container, new_user_dir) == new_container);

    for (const std::string_view path : {
             "", "relative/file", "/Documents/EmulationData/sdmc/save.bin", "fd://42",
             "/Applications/Other.app/file", "%CITRA_IOS_DATA_CONTAINER%outside",
             "%CITRA_IOS_DATA_CONTAINER%/../outside",
             "/var/mobile/Containers/Data/Application/invalid/Documents/file",
             "/var/mobile/Containers/Bundle/Application/043CB7FD-A2E7-4857-9EC4-204EC9825923/file",
         }) {
        assert(!DecodeIOSPath(path, new_user_dir));
        assert(!EncodeIOSPath(path, new_user_dir));
    }
    assert(!DecodeIOSPath(old_container + "/Documents/../../outside", new_user_dir));
    assert(!DecodeIOSPath(old_container + "/Documents/..\\outside", new_user_dir));
    assert(!DecodeIOSPath(old_user_dir, "/home/user/cytrus/"));
    assert(!EncodeIOSPath(old_user_dir, new_user_dir));
    std::cout << "PASS: relative iOS FS paths and legacy container UUID migration\n";
}

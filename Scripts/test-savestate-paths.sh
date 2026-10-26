#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_paths_dir="$(mktemp -d)"
trap 'rm -rf "$task_paths_dir"' EXIT
task_boost_root="${CLAW_TEST_BOOST_ROOT:-}"
task_fmt_root="${CLAW_TEST_FMT_ROOT:-}"
if [[ -z "$task_boost_root" ]]; then
    for task_candidate in .build-tools/boost/* /opt/homebrew/opt/boost /usr; do
        if [[ -f "$task_candidate/lib/libboost_serialization.a" ]]; then
            task_boost_root="$task_candidate"
            break
        fi
    done
fi
if [[ -z "$task_fmt_root" ]]; then
    for task_candidate in .build-tools/fmt/* /opt/homebrew/opt/fmt /usr; do
        if [[ -f "$task_candidate/lib/libfmt.a" ]]; then
            task_fmt_root="$task_candidate"
            break
        fi
    done
fi
if [[ -z "$task_boost_root" || -z "$task_fmt_root" ]]; then
    echo 'State path tests need host Boost and fmt libraries (CLAW_TEST_BOOST_ROOT / CLAW_TEST_FMT_ROOT).' >&2
    exit 2
fi
task_platform=()
if [[ "$(uname -s)" == Darwin ]]; then task_platform=(-framework CoreFoundation); fi
# Instantiate the actual archive serializers in both directions, including the
# factories and already-open handles that a restored game can use later.
"${CXX:-c++}" -std=c++20 -DENABLE_VULKAN=1 -DCLAW_DISABLE_LOGGING=1 -fsyntax-only \
    -IThirdParty/Cytrus/include -isystem "$task_boost_root/include" \
    -isystem "$task_fmt_root/include" -x c++ - <<'CPP'
#include "common/archives.h"
#include "core/file_sys/archive_extsavedata.h"
#include "core/file_sys/archive_nand.h"
#include "core/file_sys/archive_sdmc.h"
#include "core/file_sys/archive_sdmcwriteonly.h"
#include "core/file_sys/archive_source_sd_savedata.h"
#include "core/file_sys/archive_systemsavedata.h"
#include "core/file_sys/savedata_archive.h"
SERIALIZE_IMPL(FileSys::ArchiveFactory_ExtSaveData)
SERIALIZE_IMPL(FileSys::NANDArchive)
SERIALIZE_IMPL(FileSys::ArchiveFactory_NAND)
SERIALIZE_IMPL(FileSys::SDMCArchive)
SERIALIZE_IMPL(FileSys::ArchiveFactory_SDMC)
SERIALIZE_IMPL(FileSys::ArchiveFactory_SDMCWriteOnly)
SERIALIZE_IMPL(FileSys::ArchiveSource_SDSaveData)
SERIALIZE_IMPL(FileSys::ArchiveFactory_SystemSaveData)
SERIALIZE_IMPL(FileSys::SaveDataArchive)
CPP
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-macro-redefined \
    -DCLAW_DISABLE_LOGGING=1 -IThirdParty/Cytrus/include \
    -isystem "$task_boost_root/include" -isystem "$task_fmt_root/include" \
    -isystem ThirdParty/SharedDependencies/Sources/cryptopp/include \
    Tests/savestate_path_tests.cpp ThirdParty/Cytrus/common/file_util.cpp \
    ThirdParty/Cytrus/common/string_util.cpp ThirdParty/Cytrus/common/error.cpp \
    "$task_boost_root/lib/libboost_serialization.a" "$task_boost_root/lib/libboost_iostreams.a" \
    "$task_fmt_root/lib/libfmt.a" "${task_platform[@]}" -o "$task_paths_dir/state-path-tests"
"$task_paths_dir/state-path-tests" "$task_paths_dir/data"

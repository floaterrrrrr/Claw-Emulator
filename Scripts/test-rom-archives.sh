#!/bin/bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
task_archive_dir="$(mktemp -d)"
trap 'rm -rf "$task_archive_dir"' EXIT
python3 - "$task_archive_dir/game.zip" "$task_archive_dir/three-ds.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w', compression=zipfile.ZIP_DEFLATED) as archive:
    archive.writestr('../../GAME.GBA', b'fixture game data')
header = bytearray(1024)
header[0x100:0x104] = b'NCSD'
with zipfile.ZipFile(sys.argv[2], 'w', compression=zipfile.ZIP_DEFLATED) as archive:
    archive.writestr('test.3DS', header)
PY
task_archive_cc="${CC:-cc}"
task_archive_objects=()
for task_archive_source in Native/SevenZipSDK/*.c Native/ROMArchiveImport.c ThirdParty/SharedDependencies/Sources/miniz/miniz.c; do
    task_archive_object="$task_archive_dir/$(basename "${task_archive_source%.c}").o"
    task_archive_flags=()
    if [[ "$task_archive_source" == Native/SevenZipSDK/* ]]; then
        task_archive_flags=(-DZ7_PPMD_SUPPORT -DZ7_EXTRACT_ONLY)
    fi
    "$task_archive_cc" -std=c11 -O2 "${task_archive_flags[@]}" \
        -I. -IThirdParty/SharedDependencies/Sources/miniz/include \
        -c "$task_archive_source" -o "$task_archive_object"
    task_archive_objects+=("$task_archive_object")
done
"$task_archive_cc" -std=c11 -I. Tests/rom_archive_tests.c \
    "${task_archive_objects[@]}" -lm -o "$task_archive_dir/test"
"$task_archive_dir/test" Tests/ROMArchiveFixtures/one-game.7z \
    Tests/ROMArchiveFixtures/two-games.7z "$task_archive_dir/game.zip" \
    "$task_archive_dir/output" Tests/ROMArchiveFixtures/unknown-game.7z \
    Tests/ROMArchiveFixtures/game-and-readme.7z "$task_archive_dir" \
    Tests/ROMArchiveFixtures/one-3ds.7z "$task_archive_dir/three-ds.zip"

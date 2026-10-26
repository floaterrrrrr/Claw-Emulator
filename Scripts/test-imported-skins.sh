#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v swiftc >/dev/null; then echo 'SKIP: imported skin tests require Swift.'; exit 0; fi
task_skin_import_dir="$(mktemp -d)"
trap 'rm -rf "$task_skin_import_dir"' EXIT
python3 Tests/make-skin-fixtures.py "$task_skin_import_dir/fixtures"
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -c Native/SkinArchive.cpp -o "$task_skin_import_dir/zip.o"
task_skin_import_link=(-lstdc++)
if [[ "$(uname -s)" == Darwin ]]; then task_skin_import_link=(-lc++); fi
swiftc -warnings-as-errors -module-cache-path "$task_skin_import_dir/modules" -import-objc-header Native/SkinArchive.h \
    App/GameModel.swift App/GameplayLayout.swift App/ControllerSkinLayout.swift \
    App/DeltaSkinArchive.swift App/ImportedSkin.swift App/ImportedSkinLayout.swift App/SkinImageCodec.swift \
    Tests/imported_skin_tests.swift "$task_skin_import_dir/zip.o" -lz "${task_skin_import_link[@]}" -o "$task_skin_import_dir/skins"
"$task_skin_import_dir/skins" "$task_skin_import_dir/fixtures" "$@"

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v swiftc >/dev/null; then
    echo 'SKIP: game metadata checks require Swift.'
    exit 0
fi
task_artwork_dir="$(mktemp -d)"
trap 'rm -rf "$task_artwork_dir"' EXIT
swiftc -module-cache-path "$task_artwork_dir/modules" -warnings-as-errors -parse-as-library \
    App/GameFileIdentity.swift Tests/game_file_identity_tests.swift -o "$task_artwork_dir/identity"
"$task_artwork_dir/identity" "$task_artwork_dir"
swiftc -module-cache-path "$task_artwork_dir/modules" -warnings-as-errors -parse-as-library \
    App/GameModel.swift Tests/game_model_tests.swift -o "$task_artwork_dir/model"
"$task_artwork_dir/model"

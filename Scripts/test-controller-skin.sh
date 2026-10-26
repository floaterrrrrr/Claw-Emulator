#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Tests/check_skin_assets.py
if ! command -v swiftc >/dev/null; then
    echo 'SKIP: actual Swift skin geometry tests require Swift; run on your Mac.'
    exit 0
fi
task_skin_dir="$(mktemp -d)"
trap 'rm -rf "$task_skin_dir"' EXIT
swiftc -module-cache-path "$task_skin_dir/modules" -warnings-as-errors -O \
    App/GameplayLayout.swift App/ControllerSkinLayout.swift \
    Tests/controller_skin_tests.swift -o "$task_skin_dir/geometry"
"$task_skin_dir/geometry" App/ControllerSkin/control-deck.json

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_handheld_dir="$(mktemp -d)"
trap 'rm -rf "$task_handheld_dir"' EXIT
swiftc -warnings-as-errors -module-cache-path "$task_handheld_dir/modules" \
    App/GameModel.swift App/ConsoleLibraryModel.swift App/HandheldControls.swift Tests/handheld_control_tests.swift \
    -o "$task_handheld_dir/tests"
"$task_handheld_dir/tests"

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_console_dir="$(mktemp -d)"
trap 'rm -rf "$task_console_dir"' EXIT
swiftc -warnings-as-errors -module-cache-path "$task_console_dir/modules" \
    App/GameModel.swift App/ConsoleLibraryModel.swift App/AppIconPolicy.swift Tests/console_library_tests.swift \
    -o "$task_console_dir/test"
"$task_console_dir/test"

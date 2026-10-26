#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v swiftc >/dev/null; then
    echo 'SKIP: Swift geometry tests require Swift (run by macOS CI).'
    exit 0
fi
task_layout_dir="$(mktemp -d)"
trap 'rm -rf "$task_layout_dir"' EXIT
swiftc -module-cache-path "$task_layout_dir/modules" -O -warnings-as-errors App/GameplayLayout.swift Tests/gameplay_layout_tests.swift -o "$task_layout_dir/layout-tests"
"$task_layout_dir/layout-tests"

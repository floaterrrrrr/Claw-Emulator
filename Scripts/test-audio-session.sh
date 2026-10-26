#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v "${SWIFTC:-swiftc}" >/dev/null; then
    echo 'SKIP: Swift compiler required for audio activation concurrency checks.'
    exit 0
fi
task_audio_dir="$(mktemp -d)"
trap 'rm -rf "$task_audio_dir"' EXIT
for task_audio_mode in debug release; do
    task_audio_flags=(-Onone)
    if [[ "$task_audio_mode" == release ]]; then
        task_audio_flags=(-O -whole-module-optimization)
    fi
    "${SWIFTC:-swiftc}" -swift-version 5 -strict-concurrency=complete -warnings-as-errors \
        "${task_audio_flags[@]}" -module-cache-path "$task_audio_dir/modules" -parse-as-library \
        App/AudioActivation.swift Tests/audio_activation_tests.swift -o "$task_audio_dir/tests"
    echo "Audio coordinator checks: $task_audio_mode"
    "$task_audio_dir/tests"
done

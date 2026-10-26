#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
    echo "SKIP: real Apple AudioConverter tests require macOS (run by iOS build CI)."
    exit 0
fi
task_apple_audio_dir="$(mktemp -d)"
trap 'rm -rf "$task_apple_audio_dir"' EXIT
"${CXX:-clang++}" -std=c++20 -O2 -Wall -Wextra -Werror \
    -IThirdParty/Cytrus/include Tests/apple_audio_converter_tests.cpp \
    ThirdParty/Cytrus/audio_core/apple_pcm_converter.cpp \
    -framework AudioToolbox -o "$task_apple_audio_dir/apple-audio-tests"
"$task_apple_audio_dir/apple-audio-tests"

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_rasterizer_dir="$(mktemp -d)"
trap 'rm -rf "$task_rasterizer_dir"' EXIT
if [[ -d .build-headers/boost/boost && -d .build-headers/fmt/fmt ]]; then
    task_boost=.build-headers/boost
    task_fmt=.build-headers/fmt
elif [[ -n "${CLAW_TEST_BOOST_INCLUDE:-}" && -n "${CLAW_TEST_FMT_INCLUDE:-}" ]]; then
    task_boost="$CLAW_TEST_BOOST_INCLUDE"
    task_fmt="$CLAW_TEST_FMT_INCLUDE"
else
    echo 'Rasterizer tests need Boost and fmt headers; build dependencies first.' >&2
    exit 2
fi
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
    -DCLAW_DISABLE_LOGGING=1 \
    -IThirdParty/Cytrus/include -isystem "$task_boost" -isystem "$task_fmt" \
    Tests/rasterizer_address_tests.cpp -o "$task_rasterizer_dir/rasterizer-address-tests"
"$task_rasterizer_dir/rasterizer-address-tests"

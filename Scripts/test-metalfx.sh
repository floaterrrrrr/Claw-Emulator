#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_metalfx_dir="$(mktemp -d)"
trap 'rm -rf "$task_metalfx_dir"' EXIT
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -INative \
    Tests/spatial_upscale_config_tests.cpp Native/SpatialUpscaleConfig.cpp \
    -o "$task_metalfx_dir/config-tests"
"$task_metalfx_dir/config-tests"
python3 Tests/check_app_assets.py
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'SKIP: real MetalFX API/GPU test requires macOS (run by iOS build CI).'
    exit 0
fi
"${CXX:-clang++}" -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror -INative \
    -framework Foundation -framework Metal -framework MetalFX \
    Tests/metalfx_spatial_tests.mm Native/MetalFXSpatial.mm \
    -o "$task_metalfx_dir/metalfx-tests"
"$task_metalfx_dir/metalfx-tests"

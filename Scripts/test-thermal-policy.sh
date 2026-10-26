#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_thermal_dir="$(mktemp -d)"
trap 'rm -rf "$task_thermal_dir"' EXIT
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -INative \
    Tests/mobile_thermal_tests.cpp Native/SpatialUpscaleConfig.cpp -o "$task_thermal_dir/test"
"$task_thermal_dir/test"

python3 Tests/test_thermal_render_boundary.py

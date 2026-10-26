#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_device_dir="$(mktemp -d)"
trap 'rm -rf "$task_device_dir"' EXIT
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -pedantic -INative \
    Tests/mobile_device_profile_tests.cpp -o "$task_device_dir/device-tests"
"$task_device_dir/device-tests"
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'SKIP: real Foundation/Metal device probe requires macOS (run by iOS build CI).'
    exit 0
fi
"${CXX:-clang++}" -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror -INative \
    -framework Foundation -framework Metal -framework MetalFX \
    Tests/apple_device_profile_tests.mm Native/MobileDeviceProfile.mm \
    -o "$task_device_dir/apple-device-tests"
"$task_device_dir/apple-device-tests" "$task_device_dir"

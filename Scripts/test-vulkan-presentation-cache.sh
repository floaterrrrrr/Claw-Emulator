#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_vulkan_test_dir="$(mktemp -d)"
trap 'rm -rf "$task_vulkan_test_dir"' EXIT
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -I Native \
    Tests/vulkan_presentation_cache_tests.cpp -o "$task_vulkan_test_dir/presentation-cache-tests"
"$task_vulkan_test_dir/presentation-cache-tests"

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_descriptors_dir="$(mktemp -d)"
trap 'rm -rf "$task_descriptors_dir"' EXIT
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror \
    -IThirdParty/Cytrus/include Tests/descriptor_binding_range_tests.cpp \
    -o "$task_descriptors_dir/descriptor-binding-range-tests"
"$task_descriptors_dir/descriptor-binding-range-tests"

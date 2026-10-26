#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_states_dir="$(mktemp -d)"
trap 'rm -rf "$task_states_dir"' EXIT
task_state_platform=()
if [[ "$(uname -s)" == Darwin ]]; then
    "${CXX:-c++}" -std=c++20 -Wall -Wextra -Werror -fobjc-arc -c \
        Native/StateAutorelease.mm -o "$task_states_dir/autorelease.o"
    task_state_platform=("$task_states_dir/autorelease.o" -framework Foundation)
fi
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -pthread -INative -IThirdParty/Cytrus/include \
    Tests/async_state_tests.cpp "${task_state_platform[@]}" -o "$task_states_dir/state-worker-tests"
"$task_states_dir/state-worker-tests"
if command -v swiftc >/dev/null; then
    swiftc -module-cache-path "$task_states_dir/modules" -warnings-as-errors -parse-as-library \
        App/SaveStateStore.swift Tests/save_state_store_tests.swift \
        -o "$task_states_dir/store"
    "$task_states_dir/store" "$task_states_dir"
else
    echo 'SKIP: Foundation/Swift state store tests require Swift (run on macOS CI).'
fi

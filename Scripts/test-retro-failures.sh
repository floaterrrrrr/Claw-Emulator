#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_retro_failure_dir="$(mktemp -d)"
trap 'rm -rf "$task_retro_failure_dir"' EXIT
task_retro_failure_flags=(-shared -fPIC)
if [[ "$(uname -s)" == Darwin ]]; then task_retro_failure_flags=(-dynamiclib); fi
"${CXX:-c++}" -std=c++23 -O2 -Wall -Wextra -Werror -INative \
    "${task_retro_failure_flags[@]}" Tests/retro_failure_core.cpp -o "$task_retro_failure_dir/core.so"
"${CXX:-c++}" -std=c++23 -O2 -Wall -Wextra -Werror -pthread -INative \
    -IThirdParty/SharedDependencies/Sources/lodepng/include \
    Tests/retro_failure_tests.cpp Native/Retro/RetroRuntime.cpp \
    ThirdParty/SharedDependencies/Sources/lodepng/lodepng.cpp -ldl -lz -o "$task_retro_failure_dir/test"
"$task_retro_failure_dir/test" "$task_retro_failure_dir/core.so" "$task_retro_failure_dir/data"

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_presentation_dir="$(mktemp -d)"
trap 'rm -rf "$task_presentation_dir"' EXIT
task_presentation_library=(-shared -fPIC)
if [[ "$(uname -s)" == Darwin ]]; then task_presentation_library=(-dynamiclib); fi
"${CXX:-c++}" -std=c++23 -O2 -Wall -Wextra -Werror -INative \
    "${task_presentation_library[@]}" Tests/retro_failure_core.cpp -o "$task_presentation_dir/core.so"
"${CXX:-c++}" -std=c++23 -O2 -Wall -Wextra -Werror -pthread -INative -IThirdParty/Cytrus/include \
    -IThirdParty/SharedDependencies/Sources/lodepng/include \
    Tests/retro_presentation_tests.cpp Native/Retro/RetroRuntime.cpp \
    ThirdParty/SharedDependencies/Sources/lodepng/lodepng.cpp -ldl -lz -o "$task_presentation_dir/test"
"$task_presentation_dir/test" "$task_presentation_dir/core.so" "$task_presentation_dir/data"

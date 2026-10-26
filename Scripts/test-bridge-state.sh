#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_test_dir="$(mktemp -d)"
trap 'rm -rf "$task_test_dir"' EXIT
cat > "$task_test_dir/first.cpp" <<'CPP'
#include "cytrus/bridge.h"
bool second();
int main() { return cytrus::context == nullptr && second() ? 0 : 1; }
CPP
cat > "$task_test_dir/second.cpp" <<'CPP'
#include "cytrus/bridge.h"
bool second() { return cytrus::callback == nullptr; }
CPP
task_state_source=()
if [[ -f ThirdParty/Cytrus/bridge_state.cpp ]]; then
    task_state_source+=(ThirdParty/Cytrus/bridge_state.cpp)
fi
"${CXX:-c++}" -std=c++20 -Wall -Wextra -Werror -IThirdParty/Cytrus/include \
    "$task_test_dir/first.cpp" "$task_test_dir/second.cpp" "${task_state_source[@]}" \
    -o "$task_test_dir/bridge-link-test"
"$task_test_dir/bridge-link-test"
echo "PASS: bridge globals link across two translation units"

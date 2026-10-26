#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_test_dir="$(mktemp -d)"
trap 'rm -rf "$task_test_dir"' EXIT
task_common_flags=(-std=c++20 -O2 -Wall -Wextra -Werror -IThirdParty/Cytrus/include)
task_profile_flags=(
    -DSTRICT_INTERPRETER=1 -DDISABLE_JIT=1 -DHAVE_FASTINTERP=1
    -DENABLE_WEB_SERVICE=0 -DCITRA_USE_DISCORD_PRESENCE=0 -DENABLE_QT=0
    -DENABLE_REMOTE_INPUT=0
)
"${CXX:-c++}" "${task_common_flags[@]}" "${task_profile_flags[@]}" \
    Tests/mobile_profile_tests.cpp Native/GuestUrl.cpp -o "$task_test_dir/strict-profile"
"$task_test_dir/strict-profile"
"${CXX:-c++}" "${task_common_flags[@]}" -DDISABLE_JIT=1 \
    Tests/mobile_profile_tests.cpp Native/GuestUrl.cpp -o "$task_test_dir/no-jit-profile"
"$task_test_dir/no-jit-profile"
"${CXX:-c++}" "${task_common_flags[@]}" \
    Tests/mobile_profile_tests.cpp Native/GuestUrl.cpp -o "$task_test_dir/upstream-defaults"
"$task_test_dir/upstream-defaults"

expect_rejected() {
    local task_expected="$1"
    shift
    if "${CXX:-c++}" "${task_common_flags[@]}" "${task_profile_flags[@]}" "$@" \
        -x c++ -fsyntax-only - >"$task_test_dir/rejection.log" 2>&1 \
        <<< '#include "common/core_build_config.h"'; then
        echo "FAIL: contradictory mobile configuration was accepted: $*" >&2
        exit 1
    fi
    local task_diagnostic
    task_diagnostic="$(cat "$task_test_dir/rejection.log")"
    if [[ "$task_diagnostic" != *"$task_expected"* ]]; then
        echo "$task_diagnostic" >&2
        exit 1
    fi
}
expect_rejected 'STRICT_INTERPRETER requires DISABLE_JIT=1' -UDISABLE_JIT -DDISABLE_JIT=0
expect_rejected 'STRICT_INTERPRETER requires HAVE_FASTINTERP=1' -UHAVE_FASTINTERP
expect_rejected 'must disable web services, Qt, and Discord presence' -UENABLE_WEB_SERVICE -DENABLE_WEB_SERVICE=1
expect_rejected 'must disable web services, Qt, and Discord presence' -UENABLE_QT -DENABLE_QT=1
expect_rejected 'must disable web services, Qt, and Discord presence' -UCITRA_USE_DISCORD_PRESENCE -DCITRA_USE_DISCORD_PRESENCE=1
expect_rejected 'legacy desktop feature was enabled' -DENABLE_GDBSTUB=0
echo 'PASS: contradictory JIT, desktop, and missing-interpreter configurations rejected'

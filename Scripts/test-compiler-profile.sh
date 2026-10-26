#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_precision_dir="$(mktemp -d)"
trap 'rm -rf "$task_precision_dir"' EXIT
task_lto_flag=-flto
task_compiler_version="$("${CXX:-c++}" --version)"
if [[ "$task_compiler_version" == *clang* ]]; then
    task_lto_flag=-flto=full
fi
if [[ -d .build-headers/boost/boost ]]; then
    task_boost_include="$PWD/.build-headers/boost"
elif [[ "$(uname -s)" == Darwin ]]; then
    task_boost_include="$(brew --prefix boost)/include"
else
    task_boost_include=/tmp/claw-build14-deps/boost/usr/include
    if [[ ! -d "$task_boost_include/boost" ]]; then task_boost_include=/usr/include; fi
fi
"${CXX:-c++}" -std=c++20 -O3 "$task_lto_flag" -fno-fast-math -Wall -Wextra -Werror \
    -Wno-unused-parameter \
    -INative -IThirdParty/Cytrus/include -isystem "$task_boost_include" \
    Tests/compiler_precision_tests.cpp Native/InputMath.cpp -o "$task_precision_dir/precision-tests"
"$task_precision_dir/precision-tests"
# Reproduce SwiftPM's exported xxhash.h collision: the standalone header is a
# quote-only user path and Zstd's private variant is on the regular include path.
"${CC:-cc}" -std=c11 -O2 -IThirdParty/SharedDependencies/Sources/xxhash/include \
    -c ThirdParty/SharedDependencies/Sources/xxhash/xxhash.c -o "$task_precision_dir/xxhash.o"
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror \
    -iquote ThirdParty/SharedDependencies/Sources/xxhash/include \
    -IThirdParty/Zstd/lib/common -IThirdParty/Cytrus/include \
    Tests/xxhash_header_tests.cpp "$task_precision_dir/xxhash.o" -o "$task_precision_dir/hash-tests"
"$task_precision_dir/hash-tests"
echo 'PASS: standalone XXH3 hash API survives the Zstd exported-header collision'

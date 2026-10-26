#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'SKIP: real MoltenVK/MetalFX interop requires a macOS Metal GPU.'
    exit 0
fi
task_interop_dir="$(mktemp -d)"
trap 'rm -rf "$task_interop_dir"' EXIT
# iOS's bundled driver has no macOS slice. Pin the public macOS driver used by
# this GPU fixture; the final app still links the existing iOS framework.
curl --fail --location --silent --show-error --retry 3 --connect-timeout 20 --max-time 180 \
    https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-macos.tar \
    --output "$task_interop_dir/driver.tar"
printf '%s  %s\n' f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e \
    "$task_interop_dir/driver.tar" | shasum -a 256 -c -
tar -xf "$task_interop_dir/driver.tar" -C "$task_interop_dir" \
    MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib
if [[ -d .build-headers/fmt/fmt ]]; then
    task_fmt_include="$PWD/.build-headers/fmt"
else
    task_fmt_include="$(brew --prefix fmt)/include"
fi
"${CXX:-clang++}" -std=gnu++23 -O2 -fobjc-arc -fno-fast-math -Wall -Wextra -Werror \
    -Wno-unused-parameter -Wno-missing-field-initializers \
    -DCLAW_DISABLE_LOGGING=1 -DFMT_HEADER_ONLY \
    -INative -ITests -IThirdParty/Cytrus/include \
    -isystem .build-headers/boost -isystem .build-headers/vulkan -isystem .build-headers/vma \
    -isystem "$task_fmt_include" \
    -framework Foundation -framework Metal -framework MetalFX \
    Tests/metalfx_interop_tests.mm Native/MetalFXScaler.mm Native/MetalFXSpatial.mm Native/SpatialUpscaleConfig.cpp \
    -o "$task_interop_dir/interop-tests"
"$task_interop_dir/interop-tests" "$task_interop_dir/MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib"

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --dependencies-only ) ]]; then
    echo 'Usage: bash Scripts/prepare-macos.sh [--dependencies-only]' >&2
    exit 1
fi
if [[ "${CLAW_ENV_LOADED:-}" != 1 ]]; then
    exec python3 Scripts/distribution_config.py run -- bash "$PWD/Scripts/prepare-macos.sh" "$@"
fi
if [[ "$(uname -s)" != Darwin ]]; then
    echo "This step needs macOS with Xcode, locally or through the existing Xcode Cloud connection." >&2
    exit 2
fi
xcodebuild -version
swift --version
if [[ -z "${CLAW_DEPENDENCIES_PREFIX:-}" && -x "$PWD/.build-tools/local/bin/xcodegen" ]]; then
    export CLAW_DEPENDENCIES_PREFIX="$PWD/.build-tools/local"
fi
if [[ -n "${CLAW_DEPENDENCIES_PREFIX:-}" ]]; then
    export PATH="$CLAW_DEPENDENCIES_PREFIX/bin:$PATH"
fi
if [[ -z "${CLAW_DEPENDENCIES_PREFIX:-}" ]]; then
    brew install vulkan-headers cmake
    if [[ "${1:-}" != --dependencies-only ]]; then
        brew install xcodegen
    fi
else
    # Optional local tool/header prefix, useful before Homebrew supports a new OS.
    for task_header in vulkan/vulkan.h; do
        if [[ ! -f "$CLAW_DEPENDENCIES_PREFIX/include/$task_header" ]]; then
            echo "Missing dependency header: $CLAW_DEPENDENCIES_PREFIX/include/$task_header" >&2
            exit 1
        fi
    done
fi
mkdir -p .build-headers
for task_entry in "vulkan:vulkan-headers"; do
    task_alias="${task_entry%%:*}"
    task_formula="${task_entry#*:}"
    if [[ -n "${CLAW_DEPENDENCIES_PREFIX:-}" ]]; then
        task_prefix="$CLAW_DEPENDENCIES_PREFIX"
    else
        task_prefix="$(brew --prefix "$task_formula")"
    fi
    ln -sfn "$task_prefix/include" ".build-headers/$task_alias"
done
python3 Scripts/prepare-boost-headers.py

# VMA is a single-header library; it is not a Homebrew formula.
# Remove the old include-directory symlink if this checkout has one.
if [[ -L .build-headers/vma ]]; then
    rm .build-headers/vma
fi
mkdir -p .build-headers/vma
task_vma_version="3.3.0"
task_vma_sha256="90ce12fc4a2466235a09ae02905dd0c13aee80c1bbf11b331ab61230c2ceb112"
task_vma_tmp="$(mktemp .build-headers/vma/vk_mem_alloc.h.XXXXXX)"
trap 'rm -f "$task_vma_tmp"' EXIT
echo "Fetching Vulkan Memory Allocator v$task_vma_version"
curl --fail --location --silent --show-error --retry 3 \
    --connect-timeout 20 --max-time 90 \
    "https://raw.githubusercontent.com/GPUOpen-LibrariesAndSDKs/VulkanMemoryAllocator/v${task_vma_version}/include/vk_mem_alloc.h" \
    --output "$task_vma_tmp"
printf '%s  %s\n' "$task_vma_sha256" "$task_vma_tmp" | shasum -a 256 -c -
mv "$task_vma_tmp" .build-headers/vma/vk_mem_alloc.h
mkdir -p Validation/AppStore
python3 -u Scripts/rebuild-ios-dependencies.py 2>&1 | tee Validation/AppStore/dependencies.log
for task_header_alias in glslang spirv fmt; do
    ln -sfn "$PWD/ThirdParty/SharedDependencies/Artifacts/Headers/$task_header_alias" ".build-headers/$task_header_alias"
done
python3 Scripts/distribution_config.py generate
python3 Scripts/build-retro-cores.py --platform all
if [[ "${1:-}" != --dependencies-only ]]; then
    xcodegen generate --spec project.yml
fi

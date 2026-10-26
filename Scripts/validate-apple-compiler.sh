#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
    echo "Apple CPU/LTO validation requires macOS with Xcode." >&2
    exit 2
fi
task_cpu_dir="$(mktemp -d)"
trap 'rm -rf "$task_cpu_dir"' EXIT
task_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
cat > "$task_cpu_dir/probe.cpp" <<'CPP'
#include <cmath>
#include <limits>
int main() {
    volatile float value = std::numeric_limits<float>::quiet_NaN();
    return std::isnan(value) ? 0 : 1;
}
CPP
task_cpu_target=""
task_cpu_profile="${CLAW_CPU_PROFILE:-universal}"
case "$task_cpu_profile" in
    app-store) task_cpu_candidates=(generic) ;;
    universal|a15) task_cpu_candidates=(apple-a15) ;;
    latest) task_cpu_candidates=(apple-a19 apple-a18 apple-a17 apple-a16) ;;
    *) echo "Unknown CLAW_CPU_PROFILE: $task_cpu_profile" >&2; exit 1 ;;
esac
for task_candidate in "${task_cpu_candidates[@]}"; do
    if xcrun --sdk iphoneos clang++ -target arm64-apple-ios17.0 -isysroot "$task_sdk" \
        -std=c++23 -O3 -flto=full -fno-fast-math -mcpu="$task_candidate" \
        "$task_cpu_dir/probe.cpp" -o "$task_cpu_dir/ios-probe" \
        >"$task_cpu_dir/probe.log" 2>&1; then
        task_cpu_defines="$(xcrun --sdk iphoneos clang++ -target arm64-apple-ios17.0 \
            -isysroot "$task_sdk" -mcpu="$task_candidate" -dM -E -x c++ /dev/null)"
        if [[ "$task_cpu_defines" == *"#define __ARM_FEATURE_SVE "* ||
              "$task_cpu_defines" == *"#define __ARM_FEATURE_SVE2 "* ]]; then
            continue
        fi
        task_cpu_target="$task_candidate"
        break
    fi
done
if [[ -z "$task_cpu_target" ]]; then
    cat "$task_cpu_dir/probe.log" >&2
    echo "No validated Apple CPU target with full LTO is available." >&2
    exit 1
fi
# Validate the source-specific fast-math flag too, without imposing it on guest math.
xcrun --sdk iphoneos clang++ -target arm64-apple-ios17.0 -isysroot "$task_sdk" \
    -std=c++23 -O3 -flto=full -ffast-math -mcpu="$task_cpu_target" \
    -c "$task_cpu_dir/probe.cpp" -o "$task_cpu_dir/host-fast-math.o"
mkdir -p Validation
printf '%s\n' "$task_cpu_target" > Validation/cpu-target.txt
task_app_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' App/Info.plist)"
printf '{"build":%s,"profile":"%s","cpu":"%s","optimization":"O3","lto":"full","guest_fast_math":false,"host_pcm_gain_fast_math":true,"iOS_probe_compile_and_link":"PASS"}\n' \
    "$task_app_build" "$task_cpu_profile" "$task_cpu_target" > Validation/apple-compiler-flags.json
echo "PASS: iPhoneOS compile/link, O3/full LTO, CPU=$task_cpu_target, fast-math restricted to host PCM gain"

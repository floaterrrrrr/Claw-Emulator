#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_six_dir="$(mktemp -d)"
trap 'rm -rf "$task_six_dir"' EXIT
python3 Tests/test_retro_build_probes.py
python3 Tests/test_retro_header_warnings.py
python3 Tests/test_retro_submission_shutdown.py
bash Scripts/test-retro-presentation.sh
"${CXX:-c++}" -std=c++23 -O2 -Wall -Wextra -Werror -pthread -INative \
    Tests/retro_audio_ring_tests.cpp -o "$task_six_dir/audio-ring"
"$task_six_dir/audio-ring"
echo 'PASS: bounded stereo audio ring, concurrent producer/consumer and pause flush'
if command -v swiftc >/dev/null; then
    swiftc -warnings-as-errors -module-cache-path "$task_six_dir/modules" \
        App/GameModel.swift App/GameplayLayout.swift App/ControllerSkinLayout.swift \
        Tests/six_system_tests.swift -o "$task_six_dir/systems"
    "$task_six_dir/systems" App/ControllerSkin/control-deck.json
else
    echo 'SKIP: six-system Swift checks require Swift.'
fi
if [[ "${1:-}" != --real-cores ]]; then exit 0; fi
python3 Scripts/build-retro-cores.py --platform host
python3 Tests/make-retro-fixtures.py "$task_six_dir/fixtures"
"${CXX:-c++}" -std=c++23 -O2 -Wall -Wextra -Werror -pthread -INative \
    -IThirdParty/SharedDependencies/Sources/lodepng/include \
    Tests/retro_runtime_tests.cpp Native/Retro/RetroRuntime.cpp \
    ThirdParty/SharedDependencies/Sources/lodepng/lodepng.cpp -ldl -lz -o "$task_six_dir/cores"
for task_ext in gba gb gbc nes nds; do
    case "$task_ext" in
        gba) task_core=1; task_name=ClawmGBA; task_width=240; task_height=160 ;;
        gb|gbc) task_core=1; task_name=ClawmGBA; task_width=160; task_height=144 ;;
        nes) task_core=2; task_name=ClawNES; task_width=256; task_height=240 ;;
        nds) task_core=3; task_name=ClawDS; task_width=256; task_height=384 ;;
    esac
    "$task_six_dir/cores" "$task_core" "$PWD/.build-retro/Frameworks/host/$task_name.framework/$task_name" \
        "$task_six_dir/fixtures/fixture.$task_ext" "$task_six_dir/data-$task_ext" "$task_width" "$task_height"
done

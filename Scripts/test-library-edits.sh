#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_library_edit_dir="$(mktemp -d)"
trap 'rm -rf "$task_library_edit_dir"' EXIT
python3 - "$task_library_edit_dir/Library.swift" <<'PY'
from pathlib import Path
import sys
source = Path('App/Library.swift').read_text()
Path(sys.argv[1]).write_text('import Foundation\n' + source[source.index('@MainActor final class Library'):])
PY
swiftc -warnings-as-errors -module-cache-path "$task_library_edit_dir/modules" \
    App/GameModel.swift "$task_library_edit_dir/Library.swift" Tests/library_edit_tests.swift \
    -o "$task_library_edit_dir/test"
"$task_library_edit_dir/test"

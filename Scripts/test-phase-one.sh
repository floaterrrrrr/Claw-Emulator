#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_phase_dir="$(mktemp -d)"
trap 'rm -rf "$task_phase_dir"' EXIT
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -INative \
    Tests/restore_presentation_tests.cpp -o "$task_phase_dir/restore"
"$task_phase_dir/restore"
if command -v swiftc >/dev/null; then
    swiftc -parse-as-library -warnings-as-errors -module-cache-path "$task_phase_dir/modules" \
        App/LegalDocument.swift Tests/legal_document_tests.swift -o "$task_phase_dir/legal"
    "$task_phase_dir/legal" App/Legal
else
    echo 'SKIP: license reader execution requires Swift; run in macOS CI.'
fi

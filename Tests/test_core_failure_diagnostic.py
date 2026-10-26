#!/usr/bin/env python3
"""Verify the no-format critical logger using production template and sink."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    includes = ["-IThirdParty/Cytrus/include"]
    for path in (ROOT / ".build-headers/boost", ROOT / ".build-headers/fmt"):
        if path.is_dir():
            includes += ["-isystem", str(path)]
    with tempfile.TemporaryDirectory(prefix="claw-critical-") as directory:
        binary = Path(directory) / ("critical.exe" if os.name == "nt" else "critical")
        subprocess.run([os.environ.get("CXX", "c++"), "-std=c++23", "-O2", "-Wall",
                        "-Wextra", "-Werror", "-Wno-unused-parameter", "-pthread",
                        "-DCLAW_DISABLE_LOGGING=1", *includes,
                        *shlex.split(os.environ.get("CPPFLAGS", "")),
                        "Tests/core_failure_diagnostic_tests.cpp", "Native/LoggingDisabled.cpp",
                        "-o", str(binary)], cwd=ROOT, check=True)
        subprocess.run([str(binary), str(Path(directory) / "last-core-error.txt")],
                       cwd=ROOT, check=True, timeout=15)
    print("PASS: critical source locations, private-content omission, bounded concurrent writes and reset")


if __name__ == "__main__":
    main()

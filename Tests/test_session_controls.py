#!/usr/bin/env python3
"""Exercise the production session state machine with a small fake core."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    source = (ROOT / "Native/SessionControls.cpp").read_text()
    # Keep the complete production method, including the asynchronous boundary.
    method = source[source.index("namespace Claw {"):]
    harness = (ROOT / "Tests/session_controls_tests.cpp").read_text()
    with tempfile.TemporaryDirectory(prefix="claw-session-") as directory:
        cpp = Path(directory) / "session.cpp"
        binary = Path(directory) / ("session.exe" if os.name == "nt" else "session")
        cpp.write_text(harness + "\n" + method)
        platform = []
        if sys.platform == "darwin":
            platform = ["-fobjc-arc", str(ROOT / "Native/StateAutorelease.mm"),
                        "-framework", "Foundation"]
        subprocess.run([os.environ.get("CXX", "c++"), "-std=c++20", "-O2",
                        "-Wall", "-Wextra", "-Werror", "-pthread", "-INative",
                        str(cpp), *platform, "-o", str(binary)], cwd=ROOT, check=True)
        subprocess.run([str(binary)], cwd=ROOT, check=True, timeout=15)


if __name__ == "__main__":
    main()

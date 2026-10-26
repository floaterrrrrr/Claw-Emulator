#!/usr/bin/env python3
"""Exercise the startup framework inspector without an iOS runtime."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix="claw-framework-probe-") as directory:
        binary = Path(directory) / ("probe.exe" if os.name == "nt" else "probe")
        subprocess.run([os.environ.get("CXX", "c++"), "-std=c++20", "-O2", "-Wall",
                        "-Wextra", "-Werror", "-INative", "Tests/framework_probe_tests.cpp",
                        "-o", str(binary)], cwd=ROOT, check=True)
        subprocess.run([str(binary)], cwd=ROOT, check=True, timeout=10)
        source = (ROOT / "ThirdParty/Cytrus/common/dynamic_library/dynamic_library.cpp").read_text()
        start = source.index("bool DynamicLibrary::Load(")
        end = source.index("{", start) + 1
        depth = 1
        while depth:
            depth += (source[end] == "{") - (source[end] == "}")
            end += 1
        cpp = Path(directory) / "errors.cpp"
        harness = (ROOT / "Tests/dynamic_library_errors_tests.cpp").read_text()
        cpp.write_text(harness + "\nnamespace Common {\n" + source[start:end] + "\n}\n")
        binary = Path(directory) / ("errors.exe" if os.name == "nt" else "errors")
        subprocess.run([os.environ.get("CXX", "c++"), "-std=c++20", "-O2", "-Wall",
                        "-Wextra", "-Werror", "-IThirdParty/Cytrus/include", str(cpp),
                        "-o", str(binary)], cwd=ROOT, check=True)
        subprocess.run([str(binary)], cwd=ROOT, check=True, timeout=10)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Run the production page-accounting method with real ICL and a fake page table.

Assertions stay enabled. On Xcode Cloud this uses the archive toolchain's libc++,
so disabling Release assertions cannot hide the Boost.ICL lookup regression.
"""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    boost = Path(os.environ.get("CLAW_TEST_BOOST_INCLUDE", ROOT / ".build-headers/boost"))
    fmt = Path(os.environ.get("CLAW_TEST_FMT_INCLUDE", ROOT / ".build-headers/fmt"))
    if not (boost / "boost/icl/detail/assoc_container_adaptor.hpp").is_file():
        raise RuntimeError("Prepare pinned Boost headers with the ICL libc++ 22 fix first")
    source = (ROOT / "ThirdParty/Cytrus/include/video_core/rasterizer_cache/rasterizer_cache.h").read_text()
    start = source.index("template <class T>\nvoid RasterizerCache<T>::UpdatePagesCachedCount(")
    method = source[start:source.index("\n} // namespace VideoCore", start)]
    harness = (ROOT / "Tests/rasterizer_page_cache_tests.cpp").read_text()
    with tempfile.TemporaryDirectory(prefix="claw-page-cache-") as directory:
        cpp = Path(directory) / "page_cache.cpp"
        binary = Path(directory) / ("page-cache.exe" if os.name == "nt" else "page-cache")
        cpp.write_text(harness + "\nnamespace VideoCore {\n" + method + "\n}\n")
        subprocess.run([os.environ.get("CXX", "c++"), "-std=c++23", "-O2", "-UNDEBUG",
                        "-UBOOST_DISABLE_ASSERTS", "-Wall", "-Wextra", "-Werror",
                        "-Wno-unused-parameter", "-DCLAW_DISABLE_LOGGING=1",
                        "-IThirdParty/Cytrus/include", "-isystem", str(boost),
                        "-isystem", str(fmt), str(cpp), "-o", str(binary)],
                       cwd=ROOT, check=True)
        subprocess.run([str(binary)], cwd=ROOT, check=True, timeout=45)


if __name__ == "__main__":
    main()

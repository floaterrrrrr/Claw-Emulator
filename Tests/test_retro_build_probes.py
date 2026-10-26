#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Reproduce a false function detection, then repair the same cached build."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Scripts'))
spec = importlib.util.spec_from_file_location('retro_build', ROOT / 'Scripts/build-retro-cores.py')
retro = importlib.util.module_from_spec(spec)
spec.loader.exec_module(retro)


class FunctionProbeTests(unittest.TestCase):
    def test_missing_function_and_stale_cache_are_rejected(self):
        cmake = os.environ.get('CLAW_CMAKE') or shutil.which('cmake')
        if not cmake:
            self.skipTest('CMake is required for the real configure/link regression')
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'source'
            build = Path(folder) / 'build'
            source.mkdir()
            (source / 'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.19)
project(ClawFunctionProbes C)
include(CheckFunctionExists)
check_function_exists(claw_intentionally_missing_function HAVE_CLAW_MISSING)
configure_file(config.h.in config.h)
add_executable(probe probe.c)
target_include_directories(probe PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
''')
            (source / 'config.h.in').write_text('#cmakedefine HAVE_CLAW_MISSING\n')
            (source / 'probe.c').write_text('''#include "config.h"
#ifdef HAVE_CLAW_MISSING
#error A missing function was incorrectly reported as available
#endif
int main(void) { return 0; }
''')
            # Reproduce the original Cloud configuration. Archiving an object
            # with an unresolved symbol succeeds and poisons the feature cache.
            subprocess.run([cmake, '-S', str(source), '-B', str(build), '-G', 'Unix Makefiles',
                            '-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY'], check=True)
            self.assertIn('HAVE_CLAW_MISSING:INTERNAL=1', (build / 'CMakeCache.txt').read_text())
            failed = subprocess.run([cmake, '--build', str(build), '--target', 'probe'],
                                    capture_output=True, text=True)
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn('incorrectly reported as available', failed.stdout + failed.stderr)
            # Exercise the production build helper in the same directory.
            retro.cmake_build(cmake, source, build, 'probe', [], 1)
            self.assertNotIn('#define HAVE_CLAW_MISSING', (build / 'config.h').read_text())
            self.assertRegex((build / 'CMakeCache.txt').read_text(),
                             r'(?m)^CMAKE_TRY_COMPILE_TARGET_TYPE:[^=]+=EXECUTABLE$')
            subprocess.run([str(build / 'probe')], check=True)


if __name__ == '__main__':
    unittest.main()

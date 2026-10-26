#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Keep strict frontend warnings without diagnosing vendor callback comments."""
import os
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class HeaderWarningTests(unittest.TestCase):
    def setUp(self):
        self.compiler = os.environ.get('CLAW_CLANGXX') or shutil.which('clang++')
        if not self.compiler:
            self.skipTest('Clang is required to check Xcode documentation diagnostics')

    def compile(self, source, runtime=False):
        args = [self.compiler, '-x', 'c++', '-std=c++23', '-fsyntax-only',
                '-Wall', '-Wextra', '-Werror', '-Wdocumentation', '-Wdocumentation-deprecated-sync',
                '-I' + str(ROOT / 'Native'),
                '-I' + str(ROOT / 'ThirdParty/SharedDependencies/Sources/lodepng/include')]
        if runtime:
            args += [str(ROOT / 'Native/Retro/RetroRuntime.cpp')]
        else:
            args += ['-']
        return subprocess.run(args, input=source, capture_output=True, text=True)

    def test_original_vendor_comments_reproduce_cloud_failure(self):
        result = self.compile('#include "Retro/libretro.h"\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('-Wdocumentation]', result.stderr)
        self.assertIn('-Wdocumentation-deprecated-sync]', result.stderr)

    def test_runtime_compiles_with_documentation_warnings_as_errors(self):
        result = self.compile('', runtime=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_application_documentation_warnings_remain_errors(self):
        result = self.compile('''#include "Retro/RetroRuntime.hpp"
/** @param field This comment is intentionally invalid for a struct. */
struct ClawInvalidDocumentation {};
/** @deprecated This declaration intentionally lacks a deprecation attribute. */
struct ClawUnsynchronizedDeprecation {};
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('-Wdocumentation]', result.stderr)
        self.assertIn('-Wdocumentation-deprecated-sync]', result.stderr)


if __name__ == '__main__':
    unittest.main()

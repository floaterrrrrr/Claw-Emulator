# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise the actual Metal-host shutdown drain against real libdispatch."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SubmissionShutdownTests(unittest.TestCase):
    def test_completed_submissions_can_release_the_semaphore(self):
        compiler = os.environ.get('CLAW_CLANGXX') or shutil.which('clang++')
        if not compiler:
            self.skipTest('Clang is required for the libdispatch shutdown regression')
        flags = []
        if sys.platform != 'darwin':
            swift = shutil.which('swiftc')
            if not swift:
                self.skipTest('The Swift toolchain supplies libdispatch on Linux')
            folder = Path(swift).resolve().parent.parent / 'lib/swift'
            if not (folder / 'linux/libdispatch.so').is_file():
                self.skipTest('The Swift toolchain does not contain Linux libdispatch')
            flags = ['-I' + str(folder), '-L' + str(folder / 'linux'),
                     '-Wl,-rpath,' + str(folder / 'linux'), '-ldispatch']
        source = (ROOT / 'Native/Retro/RetroCore.mm').read_text()
        tail = source.split('// Wait for every in-flight command before releasing textures/layers.', 1)[1]
        tail = tail.split('void stop() noexcept', 1)[0]
        # Use production statements; this test must fail if the shutdown drain
        # again leaves permits borrowed when the semaphore is released.
        statements = re.findall(r'dispatch_semaphore_(?:wait|signal)\(inFlight[^;]+;', tail)
        self.assertTrue(statements)
        permits = int(re.search(r'inFlight = dispatch_semaphore_create\((\d+)\)', source)[1])
        setup = '''#include <dispatch/dispatch.h>
#include <atomic>
#include <cassert>
#include <thread>
#include <vector>
#include <sys/resource.h>
int main() {
    rlimit limit{0, 0}; setrlimit(RLIMIT_CORE, &limit);
    for (unsigned iteration = 0; iteration < 64; ++iteration) {
        dispatch_semaphore_t inFlight = dispatch_semaphore_create(PERMITS);
        for (unsigned i = 0; i < PERMITS; ++i) dispatch_semaphore_wait(inFlight, DISPATCH_TIME_FOREVER);
        std::atomic<unsigned> completed{0};
        auto completion = [&] {
            completed.fetch_add(1);
            dispatch_semaphore_signal(inFlight);
        };
        std::vector<std::thread> workers;
        for (unsigned i = 0; i < PERMITS; ++i) workers.emplace_back(completion);
'''.replace('PERMITS', str(permits))
        teardown = '''
        assert(completed.load() == PERMITS);
        for (auto& thread : workers) thread.join();
        dispatch_release(inFlight);
    }
}
'''.replace('PERMITS', str(permits))
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            for name, drain, succeeds in [
                ('original', '\n'.join(s for s in statements if '_wait(' in s), False),
                ('fixed', '\n'.join(statements), True),
            ]:
                path = folder / (name + '.cpp')
                path.write_text(setup + drain + teardown)
                binary = folder / name
                build = subprocess.run([compiler, '-std=c++20', '-Wall', '-Wextra', '-Werror', '-pthread',
                                        str(path), '-o', str(binary)] + flags,
                                       capture_output=True, text=True)
                self.assertEqual(build.returncode, 0, build.stderr)
                result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
                if succeeds:
                    self.assertEqual(result.returncode, 0, result.stderr)
                else:
                    self.assertNotEqual(result.returncode, 0, 'Original borrowed-permit release did not reproduce')


if __name__ == '__main__':
    unittest.main()

#!/usr/bin/env python3
"""Check real bridge/setting/pacer code together, with an injected wall clock.

Boost/fmt headers must be available (prepare-macos.sh or CPPFLAGS). GPU, audio
output and game execution are outside this test; it does not predict phone speed.
"""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def implementation(path, signature):
    source = (ROOT / path).read_text()
    start = source.index(signature)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


bridge = implementation("Native/ClawCore.mm", "void Claw3DSSetSpeed(int multiplier)")
process = implementation("Native/SessionControls.cpp", "void SessionControls::process(")
# Exercise the speed-setting prefix before asynchronous snapshot processing,
# which needs a loaded game. Keep this boundary independent of optional cheats.
process = process[:process.index("    if (operation_) {")] + "}\n"
pacer = implementation("ThirdParty/Cytrus/core/perf_stats.cpp", "void FrameLimiter::DoFrameLimiting(")
pacer = pacer.replace("Clock::now()", "TestClock::now()")
pacer = pacer.replace("std::this_thread::sleep_until", "TestSleepUntil")
sample_type = implementation("Native/ClawCore.mm", "struct PerformanceSample") + ";\n"
report = implementation("Native/ClawCore.mm", "const char* Claw3DSPerformanceReport()")

harness = r'''
#include "ClawCore.h"
#include "SessionControls.hpp"
#include "SessionGate.hpp"
#include "PerformanceWindow.hpp"
#include "common/settings.h"
#include "core/perf_stats.h"
#include <cassert>
#include <cmath>
#include <iostream>
#include <cstdio>
#include <cstring>
using namespace std::chrono_literals;
using std::chrono::microseconds;
using std::chrono::duration_cast;
namespace Settings { Values values; bool is_temporary_frame_limit = false; double temporary_frame_limit = 0; }
namespace Core { class System {}; }
namespace AudioCore { int speed = 1; void SetCoreAudioSpeed(int value) { speed = value; } }
std::mutex inputMutex;
std::atomic<bool> active{false};
Claw::SessionControls controls;
SessionGate gate;
struct TestClock {
    inline static std::chrono::steady_clock::time_point wall{};
    static auto now() { return wall; }
};
void TestSleepUntil(std::chrono::steady_clock::time_point deadline) {
    if (deadline > TestClock::wall) TestClock::wall = deadline;
}
'''
harness += bridge + "\nnamespace Claw {\n" + process + "\n}\nnamespace Core {\n" + pacer + "\n}\n"
harness += sample_type + "\nstd::mutex performanceMutex;\nPerformanceSample performanceSample;\nClaw::PerformanceWindow performanceWindow;\n" + report
harness += r'''
int main() {
    assert(std::strstr(Claw3DSPerformanceReport(), "No running sample"));
    performanceSample.valid = true;
    performanceSample.selected_speed = 2;
    performanceSample.applied_limit = 200;
    performanceSample.effective_limit = 100;
    performanceSample.pacing = {200, .04, .05, 10};
    performanceWindow.Add(1.5, .5);
    for (unsigned i = 0; i < 20; ++i) performanceWindow.Add(1.0, .5);
    assert(performanceWindow.Get().samples == 20);
    assert(performanceWindow.Get().mean == 1 && performanceWindow.Get().maximum == 1);
    assert(performanceWindow.Get().seconds == 10);
    const std::string report = Claw3DSPerformanceReport();
    assert(report.find("Native selected speed: 2x") != std::string::npos);
    assert(report.find("Applied frame limit: 200%") != std::string::npos);
    assert(report.find("Guest effective limit: 100%") != std::string::npos);
    assert(report.find("Pacer target: 200%") != std::string::npos);
    assert(report.find("Actual limiter sleep: 5.000 ms/VBlank") != std::string::npos);
    assert(report.find("Window speed mean/min/max: 1.000x / 1.000x / 1.000x") != std::string::npos);
    performanceWindow.Reset();
    assert(performanceWindow.Get().samples == 0);
    performanceWindow.Add(1, .25); performanceWindow.Add(2, .75);
    assert(performanceWindow.Get().mean == 1.75);
    assert(performanceWindow.Get().minimum == 1 && performanceWindow.Get().maximum == 2);
    performanceWindow.Add(NAN, 1); performanceWindow.Add(1, 0);
    assert(performanceWindow.Get().samples == 2);
    Core::System system;
    controls.reset();
    Claw3DSSetSpeed(4); // not running: ignore the UI request
    assert(controls.speedMultiplier == 1 && AudioCore::speed == 1);
    active = true;
    gate.begin();
    for (const bool global : {true, false}) {
        Settings::values.frame_limit.SetGlobal(global);
        for (const int selected : {1, 2, 4, 1, 2, 4, 3}) {
            const int expected = selected == 2 || selected == 4 ? selected : 1;
            Claw3DSSetSpeed(selected);
            controls.process(system, true); // a speed selected in the paused menu
            assert(controls.speedMultiplier == expected && AudioCore::speed == expected);
            if (Settings::values.frame_limit.GetValue() != expected * 100) {
                std::cerr << "Mismatch global=" << global << " selected=" << selected
                          << " applied=" << Settings::values.frame_limit.GetValue() << '\n';
                return 1;
            }
            // Reproduce settings drift without another UI speed event. The
            // previous cached-only process() left the overwritten limit intact.
            if (expected > 1) {
                Settings::values.frame_limit.SetValue(100);
                controls.process(system, false);
                assert(Settings::values.frame_limit.GetValue() == expected * 100);
            }
            for (const double temporary : {0., 100., 200.}) {
                Settings::is_temporary_frame_limit = true;
                Settings::temporary_frame_limit = temporary;
                Core::FrameLimiter limiter;
                TestClock::wall = {};
                limiter.DoFrameLimiting(0us);
                for (int frame = 1; frame <= 12; ++frame) {
                    TestClock::wall += 2ms; // simulated guest work, not a throughput benchmark
                    limiter.DoFrameLimiting(microseconds(frame * 16668));
                }
                const auto stats = limiter.TakePacingStats();
                const auto target = expected == 1 ? temporary : expected * 100.;
                assert(stats.target_percent == target && stats.calls == 13);
                const auto elapsed = duration_cast<microseconds>(TestClock::wall.time_since_epoch()).count();
                if (target > 0) assert(std::abs(elapsed - 200016 * 100 / target) <= 1);
                else assert(elapsed == 24000);
                if (expected > 1) {
                    assert(stats.requested_sleep_seconds > 0);
                    assert(std::abs(stats.actual_sleep_seconds - stats.requested_sleep_seconds) < 1e-9);
                }
                assert(limiter.TakePacingStats().calls == 0);
            }
        }
    }
    std::cout << "PASS: production 3DS speed bridge -> paused-menu application -> real switchable settings -> real limiter; global/custom settings, guest overrides, 1x/2x/4x deadlines and diagnostic reset\n";
}
'''
includes = ["-INative", "-IThirdParty/Cytrus/include"]
for path in [ROOT / ".build-headers/boost", ROOT / ".build-headers/fmt", Path("/opt/homebrew/include")]:
    if path.is_dir():
        includes += ["-isystem", str(path)]
with tempfile.TemporaryDirectory(prefix="claw-fast-core-") as directory:
    cpp = Path(directory) / "core.cpp"
    binary = Path(directory) / "core-test"
    cpp.write_text(harness)
    subprocess.run([os.environ.get("CXX", "c++"), "-std=c++23", "-O2", "-Wall", "-Wextra", "-Werror",
                    "-Wno-unused-parameter", "-pthread", "-DENABLE_VULKAN=1",
                    "-DHAVE_COREAUDIO=1", "-DCLAW_DISABLE_LOGGING=1", *includes,
                    *shlex.split(os.environ.get("CPPFLAGS", "")), str(cpp), "-o", str(binary)],
                   cwd=ROOT, check=True)
    subprocess.run([str(binary)], check=True, timeout=10)

#!/usr/bin/env python3
"""Compile the production frame-selection/recreation prefix with GPU mocks.

Checks decisions and synchronization call order, not Metal completion behavior.
"""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'ThirdParty/Cytrus/video_core/renderer_vulkan/renderer_vulkan.cpp').read_text()
start = source.index('Frame* RendererVulkan::PrepareWindowFrame(')
end = source.index('        clear_color.float32[0]', start)
implementation = source[start:end] + '        return frame;\n    }\n    return nullptr;\n}\n'
setup = r'''
#include "MobileThermal.hpp"
#include "SpatialUpscaleConfig.hpp"
#include <cassert>
#include <string>
#define CLAW_ENABLE_METALFX 1
namespace Layout {
struct FramebufferLayout { unsigned width, height; bool bottom_screen_enabled; };
FramebufferLayout SingleFrameLayout(unsigned w, unsigned h, bool b, bool) { return {w,h,b}; }
}
namespace Settings { struct Setting { bool value{}; bool GetValue() { return value; } };
struct Values { Setting use_skip_duplicate_frames; } values; }
namespace Core { struct PerfStats { static inline bool game_frames_updated = true; }; }
std::string trace;
struct Frame { unsigned width{}, height{}; bool thermal_limited{}; };
struct PresentWindow {
    Frame frame;
    Layout::FramebufferLayout RenderLayout(Layout::FramebufferLayout out) {
        const auto input = Claw::SpatialUpscaleInputScale();
        return input ? Layout::SingleFrameLayout(out.width*input/4, out.height*input/4, out.bottom_screen_enabled, false) : out;
    }
    Frame* GetRenderFrame() { return &frame; }
    void WaitPresent() { trace += 'W'; }
    void RecreateFrame(Frame* target, unsigned w, unsigned h) {
        trace += 'R'; target->width=w; target->height=h;
        target->thermal_limited=Claw::MobileThermallyLimited();
    }
};
struct RendererVulkan {
    struct Scheduler { void Finish() { trace += 'F'; } } scheduler;
    bool frame_source_changed{};
    Frame* PrepareWindowFrame(PresentWindow&, const Layout::FramebufferLayout&, bool);
};
'''
checks = r'''
int main() {
    using namespace Claw;
    ResetMobileThermal(); ConfigureSpatialUpscale(2);
    mobile_base_presentation_scale.store(4);
    RendererVulkan renderer; PresentWindow window{{800,480,false}};
    Layout::FramebufferLayout out{1600,960,false};
    renderer.PrepareWindowFrame(window,out,false); assert(trace.empty());
    mobile_applied_thermal_state.store(2);
    renderer.PrepareWindowFrame(window,out,false);
    assert(trace=="WFR" && window.frame.width==800 && window.frame.thermal_limited);
    mobile_applied_thermal_state.store(0);
    renderer.PrepareWindowFrame(window,out,false);
    // Same dimensions on recovery must still rebuild the MetalFX frame.
    assert(trace=="WFRWFR" && window.frame.width==800 && !window.frame.thermal_limited);
    trace.clear(); mobile_applied_thermal_state.store(3);
    renderer.PrepareWindowFrame(window,out,false);
    assert(trace=="WFR" && window.frame.width==400 && window.frame.height==240);
    renderer.PrepareWindowFrame(window,out,false); assert(trace=="WFR");
    PresentWindow bottom{{640,480,false}}; out={1280,960,true};
    renderer.PrepareWindowFrame(bottom,out,false);
    assert(bottom.frame.width==320 && bottom.frame.height==240);
    ConfigureSpatialUpscale(0); mobile_base_presentation_scale.store(2);
    mobile_applied_thermal_state.store(2); window.frame={800,480,false}; out={800,480,false};
    renderer.PrepareWindowFrame(window,out,false);
    assert(window.frame.width==400 && window.frame.height==240);
    ResetMobileThermal(); renderer.PrepareWindowFrame(window,out,false);
    assert(window.frame.width==800 && !window.frame.thermal_limited);
    Settings::values.use_skip_duplicate_frames.value = true;
    Core::PerfStats::game_frames_updated = false;
    assert(renderer.PrepareWindowFrame(window,out,false) == nullptr);
    renderer.frame_source_changed = true;
    assert(renderer.PrepareWindowFrame(window,out,false) == &window.frame);
}
'''
with tempfile.TemporaryDirectory(prefix='claw-thermal-boundary-') as temp:
    folder = Path(temp)
    (folder / 'test.cpp').write_text(setup + implementation + checks)
    command = shlex.split(os.environ.get('CXX', 'c++'))
    subprocess.run(command + ['-std=c++20', '-O2', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                             '-I' + str(root / 'Native'), str(folder / 'test.cpp'),
                             str(root / 'Native/SpatialUpscaleConfig.cpp'), '-o', str(folder / 'test')], check=True)
    subprocess.run([str(folder / 'test')], check=True)
print('PASS: production thermal frame decisions, same-size MetalFX recovery, both screens and wait/drain/recreate ordering')

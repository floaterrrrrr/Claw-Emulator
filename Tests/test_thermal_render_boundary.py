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
end = source.index('        frame->rendered_height = layout.height;', start)
end = source.index('\n', end) + 1
implementation = source[start:end] + '        return frame;\n    }\n    return nullptr;\n}\n'
setup = r'''
#include "MobileThermal.hpp"
#include "SpatialUpscaleConfig.hpp"
#include "RestorePresentation.hpp"
#include <cassert>
#include <string>
#define CLAW_ENABLE_METALFX 1
#undef TARGET_OS_IPHONE
#define TARGET_OS_IPHONE 1
using u32 = std::uint32_t;
namespace Layout {
struct FramebufferLayout { unsigned width, height; bool bottom_screen_enabled; };
FramebufferLayout SingleFrameLayout(unsigned w, unsigned h, bool b, bool) { return {w,h,b}; }
}
namespace Settings { struct Setting { bool value{}; bool GetValue() { return value; } };
struct Values { Setting use_skip_duplicate_frames; } values; }
namespace Core { struct PerfStats { static inline bool game_frames_updated = true; }; }
std::string trace;
struct Frame { unsigned width{}, height{}, rendered_width{}, rendered_height{}; };
struct PresentWindow {
    Frame frame;
    bool can_scale = true;
    bool SupportsScaledPresent() const { return can_scale; }
    Layout::FramebufferLayout RenderLayout(Layout::FramebufferLayout out) {
        const int base = Claw::mobile_base_presentation_scale.load();
        const bool bottom = out.bottom_screen_enabled;
        const auto input = bottom ? 0 : Claw::SpatialUpscaleConfiguredInputScale();
        const auto scale = Claw::PresentationTargetScale(base, input, bottom, can_scale);
        return Layout::SingleFrameLayout(out.width * scale / base, out.height * scale / base, bottom, false);
    }
    Frame* GetRenderFrame() { return &frame; }
    void WaitPresent() { trace += 'W'; }
    void RecreateFrame(Frame* target, unsigned w, unsigned h) {
        trace += 'R'; target->width=w; target->height=h;
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
    RendererVulkan renderer; PresentWindow window{{800,480}};
    Layout::FramebufferLayout out{1600,960,false};
    renderer.PrepareWindowFrame(window,out,false); assert(trace.empty());
    mobile_applied_thermal_state.store(2);
    renderer.PrepareWindowFrame(window,out,false);
    assert(trace.empty() && window.frame.width==800 && window.frame.rendered_width==800);
    mobile_applied_thermal_state.store(3);
    renderer.PrepareWindowFrame(window,out,false);
    assert(trace.empty() && window.frame.width==800 && window.frame.height==480);
    assert(window.frame.rendered_width==400 && window.frame.rendered_height==240);
    PresentWindow bottom{{640,480}}; out={1280,960,true};
    renderer.PrepareWindowFrame(bottom,out,false);
    assert(trace.empty() && bottom.frame.width==640 && bottom.frame.rendered_width==320);
    ResetMobileThermal();
    renderer.PrepareWindowFrame(bottom,out,false);
    assert(trace.empty() && bottom.frame.rendered_width==640 && bottom.frame.rendered_height==480);
    out={1600,960,false};
    renderer.PrepareWindowFrame(window,out,false);
    assert(trace.empty() && window.frame.rendered_width==800 && window.frame.rendered_height==480);
    PresentWindow copy_only{{1280,960}, false}; out={1280,960,true};
    mobile_applied_thermal_state.store(3);
    renderer.PrepareWindowFrame(copy_only,out,false);
    assert(trace.empty() && copy_only.frame.rendered_width==1280 && copy_only.frame.rendered_height==960);
    ConfigureSpatialUpscale(0); mobile_base_presentation_scale.store(2);
    mobile_applied_thermal_state.store(2); window.frame={800,480}; out={800,480,false};
    renderer.PrepareWindowFrame(window,out,false);
    assert(trace.empty() && window.frame.width==800 && window.frame.rendered_width==400);
    ResetMobileThermal(); renderer.PrepareWindowFrame(window,out,false);
    assert(trace.empty() && window.frame.rendered_width==800);
    out={480,800,false};
    renderer.PrepareWindowFrame(window,out,false);
    assert(trace=="WFR" && window.frame.width==480 && window.frame.rendered_height==800);
    Settings::values.use_skip_duplicate_frames.value = true;
    Core::PerfStats::game_frames_updated = false;
    assert(renderer.PrepareWindowFrame(window,out,false) == nullptr);
    renderer.frame_source_changed = true;
    assert(renderer.PrepareWindowFrame(window,out,false) == &window.frame);
    renderer.frame_source_changed = false;
    restore_presentation.Begin(); restore_presentation.Warmed();
    assert(renderer.PrepareWindowFrame(window,out,false) == &window.frame);
    for (int i=0; i<5; ++i) restore_presentation.Completed(restore_presentation.Generation());
    assert(renderer.PrepareWindowFrame(window,out,false) == nullptr);
}
'''
with tempfile.TemporaryDirectory(prefix='claw-thermal-boundary-') as temp:
    folder = Path(temp)
    binary = folder / ('test.exe' if os.name == 'nt' else 'test')
    (folder / 'test.cpp').write_text(setup + implementation + checks)
    command = shlex.split(os.environ.get('CXX', 'c++'))
    subprocess.run(command + ['-std=c++20', '-O2', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                             '-I' + str(root / 'Native'), str(folder / 'test.cpp'),
                             str(root / 'Native/SpatialUpscaleConfig.cpp'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
print('PASS: thermal render regions and recovery reuse frame storage, both screens scale safely, and resize/restore guards hold')

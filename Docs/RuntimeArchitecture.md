# Interpreter-only iOS runtime architecture

This guide describes the current thermal/haptic implementation and the next
measurement-driven optimization work. It does not claim that proposed pipeline
or interpreter changes have shipped, that an emulator can guarantee App Review,
or that thermal power has been measured to improve by 30–40%.

## What is implemented in this change

| Component | Source |
| --- | --- |
| Pure thermal response, cooling hysteresis, atomic requested/applied state | `Native/MobileThermal.hpp` |
| Public C/Objective-C++ bridge and core-owned application | `Native/ClawCore.h`, `Native/ClawCore.mm` |
| NotificationCenter observation, resume/launch refresh, memory headroom sampler | `App/GameScreen.swift`, `App/GameEngine.swift` |
| Fence-protected presentation recreation and critical presentation gate | `renderer_vulkan.cpp`, `vk_present_window.cpp` |
| Temporary spatial-upscaler bypass with retained session identity | `Native/SpatialUpscaleConfig.cpp` |
| Native 2D-core critical display cap | `Native/Retro/RetroCore.mm` |
| Model/GPU/RAM-aware retired-framebuffer budgets | `Native/MobileDeviceProfile.hpp`, `Native/MobileTransitionCache.hpp` |
| Prepared asynchronous UIKit impacts, input first | `App/GameControls.swift` |

### Swift → C → core owner

The real Swift hook is intentionally short:

```swift
observe(ProcessInfo.thermalStateDidChangeNotification) { [weak self] in
    self?.updateThermalState()
}
// Also called after load and on resume, because notification-only observation
// misses a session that starts on an already-warm phone.
private func updateThermalState() {
    guard loaded, !stopping else { return }
    engine.setThermalState(Int32(ProcessInfo.processInfo.thermalState.rawValue))
}
```

The C bridge publishes an observation and wakes the owner. It never writes core
settings from UIKit and never waits for a GPU or emulator thread:

```cpp
void Claw3DSSetThermalState(int state) {
    Claw::mobile_requested_thermal_state.store(std::clamp(state, 0, 3),
                                               std::memory_order_relaxed);
    gate.notifyWork();
}
```

After state-operation boundary coordination, the emulation worker evaluates the
observation and changes `resolution_factor` there. Normal/fair do not add a clock
read or a settings write in this branch. Serious/critical use monotonic time and
30 seconds of continuously lower severity before recovery. The saved user profile
and the MetalFX session token remain intact.

| State | Internal graphics | MetalFX | Host presentation target |
| --- | --- | --- | --- |
| Nominal/fair | Preferred profile | Preferred profile | Existing behavior |
| Serious | Preferred output >2× becomes native 2×; otherwise native 1× | Bypassed | Existing behavior |
| Critical | Native 1× | Bypassed | At most approximately 30 Hz, screenshots excepted |

A preference described as MetalFX 2× → 4× already rasterizes internally at 2×.
Serious therefore removes the spatial upscale and uses a native 2× presentation
image; it does not falsely claim that the guest rasterization changed from 4×.
The drawable stays at its established dimensions; the normal transfer scales the
smaller image. Resizing the CAMetalLayer from a render thread is unnecessary.

Each presentation slot records whether it belongs to a thermal profile. On
entry/exit the existing presentation-fence and scheduler drain protect its
recreation, even when dimensions happen to match (serious native 2× versus normal
MetalFX input 2×). Without that mode check, a same-size slot would never rebuild
its MetalFX frame on recovery. GPU completion callbacks retain session-owned
objects; a notification never destroys them. Cache invalidation uses the core's
existing resolution-change detection.

Critical skips only intermediate host presentation, flushes guest GPU commands,
and retains cache/tick bookkeeping. It does not omit guest CPU/DSP execution or
arbitrary render commands with guest-visible side effects. CPU-bound heat may
therefore still require the user to pause. Thermal state is an OS severity signal,
not a temperature sensor or a guarantee of action before hardware throttling.

### Control haptics

`UIImpactFeedbackGenerator` is UIKit's public impact API, not a custom Core Haptics
engine or another audio session. All generator use belongs to the main actor.
`HeldButton.heldDown()` latches the emulator input before enqueueing feedback:

```swift
held = true
changed?(true)
ControlHaptics.shared.press(shoulder: shoulderHaptic)
```

The shared controller owns one light and one medium generator. It prepares both
on resume and refreshes preparation at touch-down and after a pulse. Its next-main-
queue-turn block coalesces simultaneous presses, chooses medium if a shoulder is
included, and limits feedback to one pulse per 25 ms. The input path does not wait
for that block. A session-generation ticket cancels stale queued pulses on pause,
backgrounding, errors or exit. D-pad feedback occurs on a new nonempty direction,
not continuously on touch movement. Hardware-controller input is not haptically
mirrored. Settings and the game menu expose the same persistent haptics toggle.

`prepare()` needs lead time and cannot guarantee zero latency. Preparing and
firing for the first time in one block alone would not eliminate startup delay;
the resume preparation provides the useful lead. Unsupported hardware quietly
uses UIKit's normal no-feedback behavior. Tactile quality and latency need a
physical phone; Simulator cannot validate them.

## 1. Legacy hardware and jetsam

Use `hw.machine` as a startup identifier, combined with physical memory and actual
Metal feature probes. Never infer performance-core count, memory entitlement or
MetalFX availability from a marketing model alone. Current model probing is cached
once in `MobileDeviceProfile.mm`; no sysctl belongs in the interpreter loop.

Implemented retention is 8 MiB for conservative 3 GiB devices, 12 MiB for other
conservative devices, and the existing 32 MiB for modern devices. Serious trims the
optional budget to at most 8 MiB; critical retains none. Only completed, retired
surfaces are eligible for eviction. Live texture/attachment contents and guest
memory are correctness requirements, not disposable caches.

The current upload ring remains 128 MiB on conservative hardware and 512 MiB on
modern hardware, capped by `maxBufferLength`. Do not interpret those capacities as
fully resident allocations, or the retired-surface budget as a total GPU budget.
Before changing the known-good modern ring, measure allocator high-water marks and
submission fragmentation. A proposed smaller bounded staging arena must count
retiring buffers as well as the current one; growing to a new arena and keeping
both in flight can temporarily double its footprint.

For further budgeting, inventory mandatory guest RAM, file-backed ROM pages,
render targets, upload arenas, decoded-code cache, pipeline objects, state capture,
images and UI bitmaps separately. Treat Metal's `recommendedMaxWorkingSetSize` as a
GPU performance recommendation, not a per-process jetsam entitlement. Use
`currentAllocatedSize` as another allocation observation, not an amount to add to
process footprint (that double-counts unified resources). Recheck process headroom
with public `os_proc_available_memory()`, and purge completed optional resources on
warnings. The implementation samples headroom at 0.5 Hz and evicts below 192 MiB.
Warnings may arrive late or not at all; no single ceiling guarantees survival.

For native 2D cores, retain one simple Metal fullscreen pipeline and a bounded
texture/upload pool at native dimensions. A Metal blit cannot resize; a nearest-
filtered textured triangle/quad is the appropriate inexpensive scale operation.
For 3DS, retain MoltenVK and its existing renderer unless a measured profile
justifies a larger rewrite. Deduplicate pipeline keys using shader identity plus
all semantically relevant render state. Exclude resource addresses and padding;
compare full keys on hash collisions. Bound concurrent shader jobs (one on legacy
hardware initially) and reuse pipeline cache data only across compatible core,
shader-generator, driver/device and format versions. Metal shader compilation is
GPU compilation, not permission to JIT guest ARM code.

Native 1× is a sensible *proposed* thermal/battery baseline for A12–A14 heavy 3DS
workloads, but the shipped startup policy remains the documented measured profile.
A 1-in-2 presentation skip can reduce host GPU/display work; it cannot make an
interpreter that produces 20 guest FPS execute a 30 FPS game at full speed.

## 2. Interpreter scheduling and data locality

There is no public iOS API to reliably pin an ordinary emulator thread to an E or
P core. A dedicated pthread at `QOS_CLASS_USER_INITIATED` is a reasonable interactive
baseline; it is a scheduling hint, not affinity. Keep disk compression and cache
persistence at utility QoS. Do not bounce the interpreter between GCD queues or
change QoS per frame. Measure utility/default for lightweight cores only if they
continue to meet p95/p99 guest deadlines; lower priority can increase total work
and miss deadlines rather than save energy. Let CoreAudio manage its callback
thread; no custom maximum-priority time-constraint scheduling.

Keep the current blocking `SessionGate` and paced sleeps. A condition variable is
not a spinlock. `os_unfair_lock` is appropriate only for tiny synchronous ownership
changes; it is not a substitute for interruptible timed sleep and must never span
GPU fences, audio conversion, I/O or `await`. Avoid private ulock/futex interfaces.
Use release/acquire SPSC ring indices and ownership-constrained latest-frame slots
for data streams; lock-free containers alone do not solve resource lifetime.

A real guest translation-cache optimization must preserve address-space/ASID and
mapping generation, privilege, read/write/execute permission and device-memory
classification. Cross-page accesses, MMIO, unaligned behavior and self-modifying
code need the existing slow/invalidation paths. Prefer compact arrays and bounded
2-way/4-way probe sets over heap-heavy nodes, but benchmark them against the
restored Build 30/47 cache before integration. The earlier unmeasured last-PC cache
change was reverted with the performance recovery; do not reintroduce it by guess.
Only after real profiles show cache misses should you tune block size/prefetching.
Cache line sizes and L1/L2 capacity differ by core; separate producer/consumer
counters conservatively, and avoid padding every cache entry into a huge footprint.

## 3. Metal submission and presentation

Keep guest execution, GPU ownership and host presentation as separate clocks.
Use a fixed number of submission slots with resources retained until their own GPU
completion, and a latest-frame publication rather than an unbounded queue. The
existing 2D host already coalesces accelerated video and drains its two semaphore
permits before shutdown, returning the drain's permits before disposal. Never
reuse an in-flight texture just because a newer frame exists.

`CAMetalLayer.maximumDrawableCount` supports 2 or 3, not arbitrary sizes. Two is a
reasonable memory/latency starting point; three can reduce CPU/GPU bubbles at a
higher memory/latency cost and must be measured. A count semaphore alone is not a
per-texture ownership proof when work may complete out of order. Record a slot's
own completion or use a single ordered queue with a demonstrated reuse invariant.
Encode render/blit/upscale work together where dependency rules permit, acquire
`nextDrawable` late, `presentDrawable`, then commit. No per-frame
`waitUntilCompleted()` on the interpreter. `nextDrawable` itself can block; keep it
off the main/input thread and do not let it create an unlimited render-job queue.

A CADisplayLink can request host updates at the game/energy-appropriate cadence,
but it must not execute guest ticks or accumulate work if a render job is already
pending. iOS has no portable desktop-style V-Sync-disable guarantee. Vulkan must
query surface present modes; use mailbox/immediate only if advertised, with FIFO
fallback. Do not rebuild a swapchain every time speed changes. Keep the measured
inline 3DS path until a controlled A/B test proves a replacement is better.

MetalFX spatial scaling must pass the public descriptor support probe. Internal
2× → output 4× uses one quarter of native 4×'s source pixels, plus upscale/copy
cost; it is not "sub-native" relative to the original console. Temporal scaling
requires appropriate motion vectors, depth and jitter, often unavailable in this
emulator abstraction. Do not enable it by naming a descriptor alone. Spatial
scratch textures, history and output bandwidth also count against memory/energy.
No fixed thermal percentage improvement is established without device energy data.

## 4. Audio and thermal response

The real-time callback should only read a bounded PCM ring, zero/fade underruns,
and apply bounded gain. No allocation, locks, converter reconstruction, logging or
core calls there. CoreAudio conversion runs on its producer. An empty audio ring
must not block guest execution, and a full one must not grow memory: use an
explicit bounded overflow/drop policy. Clear queued mode-era audio from the
consumer/producer owners on pause, resume, restore and speed changes; resetting
both SPSC indices concurrently from the UI introduces races.

For normal playback, preserve the working guest clock and native sample rate.
A future occupancy correction should be small, bounded and tied to measured clock
drift, not an attempt to make a CPU-limited game run faster. Keep Build 47's fixed
2× ApplePCMConverter input rate in this change. If acceleration cannot be sustained,
a fixed 2× rate can still starve; silence/fade is the bounded fallback, not fabricated
speed. An alternate adaptive converter requires separate audio/latency validation.

Thermal notifications are observed on the main actor; only atomic commands cross
to the owner. Resource downscales/retirement happen behind existing GPU fences.
Thirty-second cooling hysteresis avoids quality oscillation and repeated allocation
bursts. Do not decrease guest CPU clock or drop DSP ticks to imitate thermal
performance. The current change retains selected 2×/4× targets; a CPU-bound critical
session may still need pausing and cannot be guaranteed cool by presentation cuts.

## 5. Fast-forward correctness

Selected speed changes wall-clock deadlines only; all guest CPU/DSP work continues.
Normal 2× keeps its verified ordinary presentation path. Existing 4× coalesces host
presentation to approximately 60 Hz; thermal critical coalesces either mode to a
30 Hz target, with no backlog of old visual frames. Screen captures can force a
presentation. At 2× the fixed source-rate converter produces naturally faster,
higher-pitched audio. At 4× game audio is deliberately muted and decoded PCM is
drained; other apps' music remains mixed. Preserve this explicit contract.

Do not use an FPS label as proof of accelerated guest time. Record effective guest
speed, system VBlanks/s, requested/actual limiter sleep, CPU work, GPU processing,
display time and the existing recent running window. A 30 FPS title near 60 FPS at
2× can be valid; repeating a 30 FPS image at a 60 Hz display does not prove 2×.

## Acceptance and public API references

Portable tests cover the response curve, cooldown interruption, 3×/4×/2×/1×
profiles, same-session MetalFX bypass/recovery, native cache clamps and critical
presentation cadence. Native syntax checks cover the modified Vulkan files with
MetalFX disabled. Swift source parses locally. Actual UIKit/Objective-C++/MetalFX
compilation, GPU lifetime during hot/cool transitions and tactile feel require
Apple SDK/device validation; no local iPhone performance result is claimed.

Test A12/A14, an A15/A16 device and the owner's iPhone 17 in the same warmed scene.
Compare nominal 2× to Build 47's steady baseline; exercise serious → critical →
30s cool recovery, save/restore during transitions, pause/background/return-to-
library, and unsupported MetalFX. Measure frame-time tails, guest speed, audio
underruns, available headroom, peak footprint and energy. Test haptics on/off with
rapid multi-button input and diagonal D-pad slides; input must remain identical.
App Store compliance also depends on content, distribution, privacy and other
review requirements; disabled JIT is necessary for this project, not a blanket
4.7 approval guarantee. No JIT, executable-memory entitlement or private affinity/
notification API is introduced.

- [Thermal notifications](https://developer.apple.com/documentation/foundation/processinfo/thermalstatedidchangenotification)
- [Process memory headroom](https://developer.apple.com/documentation/os/os_proc_available_memory)
- [Metal working set recommendation](https://developer.apple.com/documentation/metal/mtldevice/recommendedmaxworkingsetsize)
- [Metal drawable count](https://developer.apple.com/documentation/quartzcore/cametallayer/maximumdrawablecount)
- [Impact feedback preparation](https://developer.apple.com/documentation/uikit/uifeedbackgenerator/prepare())
- [Apple Silicon scheduling guidance](https://developer.apple.com/documentation/apple-silicon/tuning-your-code-s-performance-for-apple-silicon)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

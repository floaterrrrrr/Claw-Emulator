# GBA audio and presentation follow-up

The previous performance push built successfully in Xcode Cloud, but phone
testing still reported uneven Metroid Fusion video and delayed audio. These
changes address the retro host rather than the 3DS interpreter/renderer.

## Audio correctness and latency

The host previously ignored `RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO`. mGBA can
change its GBA PWM sample clock after startup (32768, 65536, 131072 or 262144 Hz).
Keeping the startup rate in the converter can build a backlog and play audio
at an incorrect rate. A regression using a dynamically loaded test core fails
before this fix and passes after it. The real pinned mGBA core also passes a
homebrew test that switches SOUNDBIAS from 32768 to 65536 Hz and back.

Validated AV changes update atomic timing values and increment the audio epoch,
so the converter rebuilds and playback flushes/fades old-format audio. Invalid
AV descriptors leave the valid clock unchanged. After restoring a snapshot,
the host queries AV timing again, including cores that omit the callback.

mGBA starts with 1024 output frames / 21.3 ms at 48 kHz, down from 2048 / 42.7 ms.
The callback raises the target for larger actual hardware slices or repeated
underruns, then gradually reduces extra headroom after stable playback. Converter
batches stop at the target, avoiding overshoot and dropped samples at capacity.
The source consumer trims a backlog exceeding three guest frames; this is
recovery from stale history, not continuous speed or pitch adjustment. Queue
operations remain bounded and the audio callback does no allocation, conversion
or emulation. The existing high-quality Apple resampler remains in use.

The mGBA audio-session I/O preference is 256 / 48000 seconds (5.3 ms). This is a
request, not a hardware guarantee. Route latency and actual I/O duration are now
included in copied performance reports. Bluetooth/AirPlay can add latency beyond
the app's queues. DS, NES and 3DS retain their existing output target; the 3DS
I/O preference and speed/audio implementation retain their existing behavior.

## Presentation and scheduling

The retro render thread now uses public iOS 17 `CAMetalDisplayLink` callbacks
and the drawable supplied by the callback. It requests 60 Hz while running and
30 Hz at critical thermals. There is no second sleep timer or render-thread wait
on the core. A nonblocking GPU permit allows one submission, selecting the latest
available frame at the callback; a busy GPU coalesces frames rather than creating
a queue. A three-texture upload ring remains bounded. Retro drawable layers are
framebuffer-only render targets; 3DS retains swapchain blit access.

Audio conversion and video submission threads explicitly use a stable
user-interactive QoS. Shutdown stops the render run loop, joins workers and
returns the borrowed semaphore permit after draining the GPU. The libdispatch
regression executes those production drain statements.

The HUD now reports actual unique GPU-presented FPS, returning zero for stale
presentation data. Copied reports also retain core FPS/speed and expose CPU work,
frame-to-display age, source sample clock, adaptive target, queue sizes,
underruns, stale/overflow drops and conversion errors. GBA's native refresh is
about 59.73 Hz; these changes do not accelerate its guest clock to manufacture
an exact 60 FPS number. The bundled core binary/source identity is unchanged,
preserving existing snapshot compatibility.

## Validation scope

Portable checks cover dynamic/invalid/high-rate AV updates, native audio-clock
restoration, adaptive priming/recovery, concurrent ring trimming with stereo
integrity, actual-presentation statistics, semaphore shutdown and real
GBA/GB/GBC/NES/DS input, video, audio, saves, restore and lifecycle behavior.
The default 3DS audio queue and production 1x/2x/4x speed-bridge tests pass.

The Xcode Cloud Apple AudioConverter suite additionally exercises 32768,
65536 and 262144 Hz inputs with the smaller output target, including stereo
tone frequency, bounded writes and starvation recovery. These Apple framework
tests and the full Objective-C++/Swift iOS build require macOS. Linux checks do
not establish on-device frame pacing, end-to-end audio latency or Metroid Fusion
performance; compare the new TestFlight build on the same phone and audio route.

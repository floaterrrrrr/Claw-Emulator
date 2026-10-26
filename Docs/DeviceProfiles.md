# Device profiles and memory limits

Xcode Cloud explicitly builds the `app-store` CPU profile (generic arm64).
Device tuning below is runtime policy, not an instruction-set compatibility label.
The historical Build 24 A15/latest artifacts are not the current TestFlight path.

Hardware discovery in `Native/MobileDeviceProfile.mm` caches `hw.machine`, physical
RAM, Apple GPU family, maximum buffer size and MetalFX support once. It writes
`EmulationData/device-profile.json`; no device probing runs per emulated frame.
Model identifiers are not marketing chip numbers: for example `iPhone18,3` is an
iPhone 17. GPU features and memory are probed for resource budgets and optional MetalFX.

| Current startup rendering | Policy |
| --- | --- |
| A12/A13 identifiers, at most 3 GiB RAM, or Simulator | Native 1× |
| Other supported/unknown phones, including iPhone 17 | Native 2× |

The automatic iPhone 17 profile no longer pays for 4× presentation buffers and
spatial scaling on every frame. 2× → 4× MetalFX remains available in manual settings.

Manual settings remain available. The guest CPU clock stays at 100%; this is not
an iPhone CPU utilization percentage. All emulator JIT paths remain disabled.

| Additional memory limit | 3 GiB conservative | Other conservative | Modern |
| --- | --- | --- | --- |
| Retired completed framebuffer cache | 8 MiB | 12 MiB | 32 MiB |
| Completed surfaces retained | 4 | 4 | 8 |
| Maximum idle age | 4 emulated frames | 4 emulated frames | Existing unlimited-age policy |
| Upload ring capacity | 128 MiB | 128 MiB | 512 MiB |

Apple GPU families below Apple8, at most 4 GiB RAM, unknown GPU probes, and known
older iPhone identifiers use conservative retention. Upload capacity is also
bounded by the device's maximum buffer length. These are capacity/budget limits,
not measured resident-memory totals. Active and in-flight resources are outside
the optional retired-framebuffer cache and remain GPU-fence protected.

Thermal protection is transient; it does not overwrite saved graphics preferences.
Nominal/fair retain the preferred profile. Serious changes 4×/3× output to native
2×, or native 2× to 1×, and bypasses MetalFX. Critical uses native 1× and caps host
presentation at a 30 Hz target. Lower thermal states must remain stable for 30
seconds before quality recovers. Serious limits optional retention to at most
8 MiB; critical retains no idle transition surfaces. Core execution and audio
continue independently of presentation; guest frames/ticks are not skipped.
DS/GBA/GB/GBC/NES already render natively and only need the critical presentation cap.

Memory warnings release optional transition retention. The existing UI status
sampler also checks public `os_proc_available_memory()` every two seconds and
requests that release below 192 MiB of reported process headroom (zero/unknown is
ignored). This is an early eviction threshold, not an OS memory entitlement.
There is no guaranteed 1.4 GiB jetsam ceiling across devices or OS versions; guest
RAM, ROM pages, GPU resources, shader caches, state capture and images also count.

`Scripts/test-mobile-device-profile.sh` checks hardware selection and completed-
resource retention; its Apple probe runs on macOS. `Scripts/test-thermal-policy.sh`
checks the response curve, hysteresis, cache clamp, MetalFX session preservation
and 30 Hz presentation gate. Runtime quality, memory pressure, audio continuity,
frame-time tails and thermal recovery still need real-device testing.

# Frontend and core wiring

The executable frontend code is in `App/GameScreen.swift`. SwiftUI presents a
UIKit `GameController` through `UIViewControllerRepresentable`. UIKit owns the
layout and touch overlay; Cytrus owns GPU rendering into the two CAMetalLayers.

```text
┌────────────────────────────────────┐
│ FPS / speed          Pause    Stop │
├────────────────────────────────────┤
│ Top display: 400 × 240             │
│ Physical drawable: native or 2×    │
├────────────────────────────────────┤
│ Bottom display: 320 × 240          │
│ Touch maps into this framebuffer  │
├────────────────────────────────────┤
│   L       Select    Start      R  │
│ Circle pad   D-pad       X         │
│                      Y     A      │
│                         B         │
└────────────────────────────────────┘
```

The controls are children of the same root canvas, added after the rendering
views. They sit below the screens so they do not cover Pokémon Y's touch UI.
UIKit hit-testing routes button touches to the HUD and bottom-screen touches to
the touchscreen mapper. Portrait is the initial supported layout.

## Layout code

The main constraints preserve both native aspect ratios:

```swift
top.widthAnchor.constraint(equalTo: safe.widthAnchor, constant: -24)
top.heightAnchor.constraint(equalTo: top.widthAnchor, multiplier: 240.0 / 400.0)
bottom.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 12)
bottom.widthAnchor.constraint(equalTo: top.widthAnchor, multiplier: 0.8)
bottom.heightAnchor.constraint(equalTo: bottom.widthAnchor, multiplier: 240.0 / 320.0)
inputArea.topAnchor.constraint(equalTo: bottom.bottomAnchor, constant: 16)
```

`MetalScreen.layerClass` returns `CAMetalLayer.self`. The drawable sizes are
`400 × 240 × resolution` and `320 × 240 × resolution`, independent of the
phone's Retina screen scale. Core window metadata uses a surface scale of 1.
An explicitly selected 2× profile doubles each drawable dimension.

## Touch and buttons

Touch coordinates are converted in the view's local space:

```swift
let point = value.location(in: self)
let mapped = Claw3DSMapTouch(
    Float(point.x), Float(point.y), Float(bounds.width), Float(bounds.height),
    Int32(nativeSize.width), Int32(nativeSize.height)
)
touch?(CGPoint(x: CGFloat(mapped.x), y: CGFloat(mapped.y)), down)
```

`Native/InputMath.cpp` clamps normalized coordinates and scales them to the last
valid framebuffer pixel. Invalid surface dimensions and NaN/Infinity are
rejected. The core maps framebuffer coordinates into its normalized touchscreen
state; only the lower display forwards these events.

The overlay uses named `PadKey` cases. Button-down calls `Claw3DSButton(code, true)`;
up, cancellation, or dragging outside calls `Claw3DSButton(code, false)`.

| Control | Core ID |
|---|---:|
| A / B / X / Y | 700 / 701 / 702 / 703 |
| Start / Select | 704 / 705 |
| Up / Down / Left / Right | 709 / 710 / 711 / 712 |
| Circle pad | 713, analog −1…1 |
| L / R | 773 / 774 |

The circle pad clamps the drag to a unit circle and inverts UIKit's downward Y
axis. D-pad directions can be held together for diagonals. Gamepad buttons use
position-based mapping. Holds are tracked per input source, preventing one
controller's button release from cancelling the same button on the touch HUD.
Pause, disconnect, and stop clear held buttons, analog movement, and touch.

## Ownership and synchronization

- UIKit creation, view layout, button state, and alerts stay on the main queue.
- Load and stop run on a serial core queue, separate from UI work.
- The emulation thread submits both screens through the core's Vulkan scheduler;
  each window can have its own presentation worker. The frontend does not add
  independent render loops that mutate the core concurrently.
- `ClawCore.mm` holds strong ARC references to both Metal layers. The Swift
  controller also stays alive until stop completes.
- A condition variable blocks the paused CPU loop. Stop wakes that wait and
  requests shutdown. The core thread is joined before system teardown.
- Renderer shutdown waits for both presentation windows. Each `PresentWindow`
  explicitly stops, notifies, and joins its worker **before** freeing its Vulkan
  resources. Layers are released after system and window destruction.
- The input mutex protects input/window access against teardown. It is not held
  while joining the CPU thread. Core touch and button state also have their own
  upstream mutexes. FPS and speed snapshots use atomics, so UI sampling does not
  lock the renderer or core.

The portable tests validate mapping and the pause gate. GPU ownership and lock
ordering were reviewed in source; they still need Thread Sanitizer, Instruments,
and actual-device checks. Driver-level hangs or iOS 27 compatibility have not
been ruled out.

## Files created or changed

Created app files: `App/ClawApp.swift`, `App/Library.swift`,
`App/GameScreen.swift`, `App/Info.plist`.

Created bridge and validation files: `Native/ClawCore.h`, `Native/ClawCore.mm`,
`Native/InputMath.cpp`, `Native/SessionGate.hpp`, the files in `Tests/`,
`Scripts/`, `project.yml`, and `.github/workflows/build-ios.yml`.

Modified upstream sources: `ThirdParty/Cytrus/emu_window_vk.cpp`,
`video_core/renderer_vulkan/renderer_vulkan.cpp`,
`video_core/renderer_vulkan/vk_present_window.cpp`, `include/cytrus/bridge.h`,
and `bridge.cpp`. Added `ThirdParty/Cytrus/bridge_state.cpp`.

Phase 1: license rendering, safe 3DS restore, and display polish

Scope

- `App/LegalDocument.swift` and `LegalDocumentView.swift`: load documents on an actor, retain all notice text, and render bounded 4,096-character sections lazily. Missing, empty, and unreadable documents have explicit recovery text.
- `App/Claw.entitlements`, `Claw.xcodeproj`, and `project.yml`: enable Increased Memory Limit for app configurations. Register the new license reader in the app project and the frontend fixture. The signed-archive validator checks the entitlement.
- `Native/SessionControls.*` and `ClawCore.*`: preflight decompression headroom; drain old renderer work at the exclusive restore boundary; reacquire the rasterizer after deserialization; load persistent shader resources before execution resumes. Migrate the shader cache to Application Support/ShaderCache using a staged copy, retaining the old cache if migration fails. The Vulkan driver cache remains in Library/Caches.
- `Native/RestorePresentation.hpp` and Vulkan renderer/presentation code: stamp frames with a restore generation; count only matching top-screen frames with valid framebuffer sources after their existing presentation fences complete. Bypass MetalFX for the first three completed frames and reveal the display after five. Old GPU slots cannot satisfy a new restore. No additional steady-state fence or device-idle wait is introduced.
- `Native/MetalFXSpatial.*` and `MetalFXScaler.mm`: validate logical dimensions, formats, and device identity before encoding. A transient mismatch uses the normal Vulkan blit without disabling a healthy scaler or waiting on an unsubmitted MetalFX event.
- `App/GameScreen.swift`, `GameEngine.swift`, and `SaveStateStore.swift`: cover boot/restore with a bounded preview and loading indicator; decode/encode images on utility workers. Optional previews use atomic `.cst.hires.png` sidecars, up to 1,600 x 960 and 8 MiB. Match the saved file date before attachment, fall back to existing `.cst.png` previews, reject stale previews, and remove both images on deletion. Existing Start from boot recovery actions remain available.
- Layout/settings files: add the opt-in Proportional Bottom Screen setting for 3DS. Fit 400x240 and 320x240 displays at one common pixel scale inside their existing slots, preserving controls and full images. The lower display uses bilinear filtering and bypasses MetalFX. Touch coordinates use the final lower-display bounds and retain native 320x240 mapping.
- Tests and CI: cover license integrity/Unicode, restore generations, renderer replacement ordering, preflight rejection, sidecar bounds/freshness/deletion, phone/skin geometry, and proportional-size touch coordinates. Add the Phase 1 tests to portable validation and Xcode Cloud post-clone checks.

Compatibility boundaries

- `ThirdParty/Cytrus/core/savestate.cpp`, `ThirdParty/Cytrus/include/core/savestate.h`, and `ThirdParty/Cytrus/common/scm_rev.cpp` are unchanged from the base commit. The existing CST header, archive layout, compression reader, and core revision remain unchanged.
- No packaged core/dependency binaries or license texts are changed. Phase 2 artwork lookup and `PrivacyPolicy.txt` changes are deferred.
- Proportional mode defaults off. A constrained landscape touch-screen slot can reduce the main display size when the user enables a common pixel scale.

Local validation

- PASS: the complete `Scripts/check-build.sh --portable` sequence with the Linux adapters described below. Apple-only checks explicitly skip; the host mock benchmark does not measure iPhone performance.
- PASS: Phase 1 C++ policy and Swift license tests; complete reconstruction of all five bundled legal documents.
- PASS: production session save/restore state machine, including replacement of the renderer during ApplyStateSnapshot and rejection before decompression when memory is insufficient.
- PASS: save-store regression tests, including unchanged CST bytes and rejection of a delayed preview after a slot overwrite.
- PASS: gameplay and built-in skin layout tests, native touch mapping, six-system layout/control checks, mobile presentation, thermal render boundaries, fast-forward bridge, diagnostic and distribution checks.
- PASS: Swift parser check of all changed Swift source files; C++ syntax check of the changed Vulkan renderer/presenter with MetalFX and the iOS presentation branch enabled.
- PASS: project source membership, entitlement/resource checks, public-source audit, and whitespace checks.
- Linux test environment: Swift 6.1.3; save-store and imported-skin tests use a temporary local-file NSFileCoordinator shim because swift-corelibs-foundation does not implement Apple's file-provider coordinator. GCC's pre-existing range-loop-copy warning in the page-cache fixture is disabled for the portable run; that fixture also passes unchanged with Clang. These test adapters do not change shipped source or exercise iCloud/Files provider behavior.
- Pending: full iOS compile/link/archive, provisioning-profile entitlement validation, actual MetalFX/GPU validation, and on-device Continue/restore/rotation/touch testing. Xcode and an Apple GPU are unavailable in this workspace. A portable check is not an iOS build confirmation.

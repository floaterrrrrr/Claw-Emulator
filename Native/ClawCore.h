// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef CLAW_NATIVE_CLAW_CORE_H
#define CLAW_NATIVE_CLAW_CORE_H
#include <stdbool.h>
#include <stdint.h>
#include "Retro/RetroCore.h"
#include "SkinArchive.h"
#include "ROMArchiveImport.h"
#ifdef __cplusplus
extern "C" {
#endif
// Load/stop run on the frontend's serial worker queue. Layers remain alive until stop completes.
int Claw3DSLoad(const char* rom, const char* dataDirectory, void* topLayer, void* bottomLayer,
             int resolution, int cpuClock, bool asyncShaders, int upscaleInput);
// Extract the decrypted, bootable main NCCH from a base-game CIA into a staged .app file.
// 0 success, 1 invalid archive, 2 encrypted, 3 update/DLC/non-game, 4 read/write failure.
int Claw3DSExtractCIA(const char* source, const char* destination);
bool Claw3DSMetalFXSupported(void);
// 0 off, 2 ready, 1 active, -1 unavailable (native 4x fallback).
int Claw3DSMetalFXStatus(void);
const char* Claw3DSMetalFXError(void);
const char* Claw3DSLastError(void);
void Claw3DSStop(void);
// Nonblocking request; Claw3DSStop on the serial worker performs the join/cleanup.
void Claw3DSRequestStop(void);
void Claw3DSPause(bool paused);
void Claw3DSRequestPipelineCacheSave(void);
void Claw3DSSetFastForward(bool enabled);
// 1/2/4x targets; 4x intentionally mutes game audio.
void Claw3DSSetSpeed(int multiplier);
void Claw3DSSetVolume(float volume);
void Claw3DSMemoryPressure(void);
// UIKit publishes 0 nominal / 1 fair / 2 serious / 3 critical. No settings
// mutation or GPU wait occurs here; the owner applies it at a safe boundary.
void Claw3DSSetThermalState(int state);
int Claw3DSAppliedThermalState(void);
uint64_t Claw3DSAvailableMemoryBytes(void);
// Requests run at an emulation-thread boundary, including while paused.
uint64_t Claw3DSCurrentTitle(void);
// Startup recommendations share the engine's capability-checked policy.
const char* Claw3DSDeviceModel(void);
int Claw3DSDefaultResolution(void);
int Claw3DSDefaultMetalFXInput(void);
bool Claw3DSSaveState(int slot);
bool Claw3DSLoadState(int slot);
// 0 idle, 1 pending, 2 saved, 3 restored, -1 failed.
int Claw3DSStateStatus(void);
const char* Claw3DSStateError(void);
bool Claw3DSIsRunning(void);
// Status 16 is a normal guest/core shutdown request, not a file-lock failure.
bool Claw3DSDidRequestShutdown(void);
// Shared limits keep the Swift surfaces and native renderer in agreement.
int Claw3DSResolutionScale(int requested);
int Claw3DSPresentationScale(int requested);
typedef struct { float x, y; } Claw3DSTouchPoint;
// Returns {-1,-1} for an invalid surface or non-finite input.
Claw3DSTouchPoint Claw3DSMapTouch(float x, float y, float viewWidth, float viewHeight,
                          int framebufferWidth, int framebufferHeight);
void Claw3DSButton(int button, bool pressed);
void Claw3DSAnalog(float x, float y);
void Claw3DSTouch(float x, float y, bool down);
double Claw3DSFPS(void);
double Claw3DSSpeed(void);
// Last running sample, retained while the menu is paused. No ROM paths or user IDs.
const char* Claw3DSPerformanceReport(void);
#ifdef __cplusplus
}
#endif

#endif // CLAW_NATIVE_CLAW_CORE_H

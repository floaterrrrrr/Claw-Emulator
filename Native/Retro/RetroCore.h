// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef CLAW_RETRO_CORE_H
#define CLAW_RETRO_CORE_H
#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
int ClawRetroLoad(int core, uint64_t title, const char* rom, const char* dataDirectory,
                  void* topLayer, void* bottomLayer);
void ClawRetroStop(void);
void ClawRetroRequestStop(void);
void ClawRetroPause(bool value);
void ClawRetroSetSpeed(int value);
void ClawRetroSetVolume(float value);
void ClawRetroButton(int key, bool pressed);
void ClawRetroAnalog(float x, float y);
void ClawRetroTouch(float x, float y, bool down);
bool ClawRetroState(int slot, bool restore);
int ClawRetroStateStatus(void);
bool ClawRetroIsRunning(void);
// Actual unique GPU-presented rate; the report separately includes core FPS.
double ClawRetroFPS(void);
const char* ClawRetroPerformanceReport(void);
const char* ClawRetroError(void);
#ifdef __cplusplus
}
#endif
#endif

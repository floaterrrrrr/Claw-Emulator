// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Bounded ZIP stored/raw-deflate decode with CRC verification. No filesystem I/O.
bool ClawSkinDecode(const uint8_t* source, size_t sourceSize, uint8_t* destination,
                    size_t destinationSize, uint16_t method, uint32_t expectedCRC);
#ifdef __cplusplus
}
#endif

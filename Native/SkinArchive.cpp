// SPDX-License-Identifier: GPL-3.0-or-later
#include "SkinArchive.h"
#include <cstring>
#include <zlib.h>
bool ClawSkinDecode(const uint8_t* source, size_t sourceSize, uint8_t* destination,
                    size_t destinationSize, uint16_t method, uint32_t expectedCRC) {
    constexpr size_t limit = 16 * 1024 * 1024;
    if ((!source && sourceSize) || (!destination && destinationSize) ||
        sourceSize > limit || destinationSize > limit) return false;
    if (method == 0) {
        if (sourceSize != destinationSize) return false;
        if (sourceSize) std::memcpy(destination, source, sourceSize);
    } else if (method == 8) {
        if (!source || !sourceSize) return false;
        uint8_t emptyOutput{};
        z_stream stream{};
        stream.next_in = const_cast<Bytef*>(source); stream.avail_in = static_cast<uInt>(sourceSize);
        stream.next_out = destinationSize ? destination : &emptyOutput;
        stream.avail_out = destinationSize ? static_cast<uInt>(destinationSize) : 1;
        if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return false;
        const int status = inflate(&stream, Z_FINISH);
        const bool valid = status == Z_STREAM_END && stream.total_out == destinationSize && stream.avail_in == 0;
        inflateEnd(&stream);
        if (!valid) return false;
    } else return false;
    return crc32(0, destination, static_cast<uInt>(destinationSize)) == expectedCRC;
}

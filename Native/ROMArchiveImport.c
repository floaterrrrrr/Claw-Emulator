// SPDX-License-Identifier: GPL-3.0-or-later
#define _POSIX_C_SOURCE 200809L
// Archive entries are selected by type and written to a fixed destination.
// Paths from an archive never become filesystem paths.
#include "ROMArchiveImport.h"
#include "SevenZipSDK/7z.h"
#include "SevenZipSDK/7zAlloc.h"
#include "SevenZipSDK/7zCrc.h"
#include "SevenZipSDK/7zFile.h"
#include <miniz/miniz.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <sys/statvfs.h>
#include <unistd.h>
#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

static const ISzAlloc alloc = { SzAlloc, SzFree };

struct Claw3DSArchiveImportToken {
    atomic_int cancelled;
    atomic_int phase;
    atomic_ullong completed;
    atomic_ullong total;
};

Claw3DSArchiveImportToken *Claw3DSArchiveImportTokenCreate(void) {
    return calloc(1, sizeof(Claw3DSArchiveImportToken));
}
void Claw3DSArchiveImportTokenCancel(Claw3DSArchiveImportToken *token) {
    if (token) atomic_store(&token->cancelled, 1);
}
void Claw3DSArchiveImportTokenDestroy(Claw3DSArchiveImportToken *token) { free(token); }
void Claw3DSArchiveImportTokenProgress(const Claw3DSArchiveImportToken *token,
                                    unsigned long long *completed, unsigned long long *total, int *phase) {
    if (completed) *completed = token ? atomic_load(&token->completed) : 0;
    if (total) *total = token ? atomic_load(&token->total) : 0;
    if (phase) *phase = token ? atomic_load(&token->phase) : 0;
}
static int cancelled(const Claw3DSArchiveImportToken *token) {
    return token && atomic_load(&token->cancelled);
}
static void progress(Claw3DSArchiveImportToken *token, int phase,
                     unsigned long long completed, unsigned long long total) {
    if (!token) return;
    atomic_store(&token->phase, phase);
    atomic_store(&token->completed, completed);
    atomic_store(&token->total, total);
}

// The 7-Zip decoder needs a contiguous output block. Back it with a temporary
// file so multi-GB 3DS games don't require multi-GB resident memory.
typedef struct {
    ISzAlloc api;
    const char *directory;
    void *mapped;
    size_t length;
    char path[PATH_MAX];
} MappedOutput;

static void *mapped_alloc(ISzAllocPtr allocator, size_t size) {
    MappedOutput *output = (MappedOutput *)allocator;
    if (!size || output->mapped) return NULL;
    int count = snprintf(output->path, sizeof(output->path), "%s/claw-7z-XXXXXX", output->directory);
    if (count < 0 || (size_t)count >= sizeof(output->path)) return NULL;
    int fd = mkstemp(output->path);
    if (fd < 0) return NULL;
    if (ftruncate(fd, (off_t)size) != 0) {
        close(fd);
        unlink(output->path);
        output->path[0] = 0;
        return NULL;
    }
    void *mapped = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (mapped == MAP_FAILED) {
        unlink(output->path);
        output->path[0] = 0;
        return NULL;
    }
    output->mapped = mapped;
    output->length = size;
    return mapped;
}

static void mapped_free(ISzAllocPtr allocator, void *address) {
    MappedOutput *output = (MappedOutput *)allocator;
    if (address && address == output->mapped) {
        munmap(address, output->length);
        output->mapped = NULL;
        output->length = 0;
        if (output->path[0]) {
            unlink(output->path);
            output->path[0] = 0;
        }
    }
}

static int supported(const char *ext) {
    static const char *const extensions[] = {
        "3ds", "cci", "cxi", "app", "cia", "3dsx", "nds", "srl",
        "gba", "gb", "gbc", "sgb", "nes", "unif", "unf"
    };
    for (size_t i = 0; i < sizeof(extensions) / sizeof(extensions[0]); i++)
        if (strcmp(ext, extensions[i]) == 0) return 1;
    return 0;
}

static int zip_extension(const char *name, char *ext, unsigned capacity) {
    const char *dot = strrchr(name, '.');
    if (!dot || capacity < 2) return 0;
    size_t len = strlen(++dot);
    if (len == 0 || len >= capacity || len > 8) return 0;
    for (size_t i = 0; i < len; i++) {
        char c = dot[i];
        if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))) return 0;
        ext[i] = c;
    }
    ext[len] = 0;
    return supported(ext);
}

static int seven_extension(const CSzArEx *db, UInt32 index, char *ext, unsigned capacity) {
    size_t length = SzArEx_GetFileNameUtf16(db, index, NULL);
    if (length < 3 || length > 4096 || capacity < 2) return 0;
    UInt16 name[4096];
    SzArEx_GetFileNameUtf16(db, index, name);
    size_t dot = length;
    while (dot > 0 && name[--dot] != '.') {}
    if (name[dot] != '.') return 0;
    size_t len = length - dot - 2; // length includes the terminator
    if (len == 0 || len >= capacity || len > 8) return 0;
    for (size_t i = 0; i < len; i++) {
        UInt16 c = name[dot + 1 + i];
        if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))) return 0;
        ext[i] = (char)c;
    }
    ext[len] = 0;
    return supported(ext);
}

typedef struct {
    FILE *file;
    Claw3DSArchiveImportToken *token;
    unsigned long long written;
} ZipOutput;

static size_t zip_write(void *context, mz_uint64 offset, const void *data, size_t size) {
    ZipOutput *output = context;
    if (cancelled(output->token) || offset != output->written) return 0;
    size_t written = fwrite(data, 1, size, output->file);
    output->written += written;
    if (output->token) atomic_store(&output->token->completed, output->written);
    return written;
}

static int extract_zip(const char *source, const char *destination,
                       char *outExtension, unsigned capacity, unsigned long long maxBytes,
                       Claw3DSArchiveImportToken *token) {
    mz_zip_archive archive = {0};
    if (!mz_zip_reader_init_file(&archive, source, 0)) return 1;
    int result = 1;
    mz_uint selected = 0, found = 0, fallback = 0, unknown = 0;
    mz_uint64 fallbackSize = 0, secondSize = 0;
    char ext[16], selectedExt[16] = {0};
    mz_zip_archive_file_stat stat;
    mz_uint count = mz_zip_reader_get_num_files(&archive);
    if (count > 4096) goto end;
    for (mz_uint i = 0; i < count; i++) {
        if (!mz_zip_reader_file_stat(&archive, i, &stat)) goto end;
        if (stat.m_is_directory || !stat.m_uncomp_size) continue;
        if (zip_extension(stat.m_filename, ext,
            capacity < sizeof(ext) ? capacity : (unsigned)sizeof(ext))) {
            if (++found > 1) { result = 2; goto end; }
            selected = i;
            strcpy(selectedExt, ext);
        } else {
            unknown++;
            if (stat.m_uncomp_size > fallbackSize) {
                secondSize = fallbackSize;
                fallbackSize = stat.m_uncomp_size;
                fallback = i;
            } else if (stat.m_uncomp_size > secondSize) secondSize = stat.m_uncomp_size;
        }
    }
    if (!found && fallbackSize >= 4096 && (unknown == 1 ||
        (secondSize <= 1024 * 1024 && fallbackSize > secondSize * 10))) {
        selected = fallback;
        strcpy(selectedExt, "bin");
        found = 1;
    }
    if (!found) { result = 7; goto end; }
    if (!found || !mz_zip_reader_file_stat(&archive, selected, &stat)) goto end;
    if (stat.m_uncomp_size == 0 || stat.m_uncomp_size > maxBytes) { result = 3; goto end; }
    if (!stat.m_is_supported || stat.m_is_encrypted) { result = 6; goto end; }
    if (cancelled(token)) { result = 5; goto end; }
    FILE *output = fopen(destination, "wb");
    if (!output) { result = 4; goto end; }
    ZipOutput writer = { output, token, 0 };
    progress(token, 1, 0, stat.m_uncomp_size);
    mz_bool extracted = mz_zip_reader_extract_to_callback(&archive, selected, zip_write, &writer, 0);
    int closeResult = fclose(output);
    if (cancelled(token)) { result = 5; goto end; }
    if (!extracted || closeResult != 0 || writer.written != stat.m_uncomp_size) { result = 4; goto end; }
    memcpy(outExtension, selectedExt, strlen(selectedExt) + 1);
    result = 0;
end:
    mz_zip_reader_end(&archive);
    return result;
}

typedef struct {
    CFileInStream file;
    SRes (*originalRead)(ISeekInStreamPtr, void *, size_t *);
    Claw3DSArchiveImportToken *token;
} MonitoredInput;

static SRes monitored_read(ISeekInStreamPtr stream, void *data, size_t *size) {
    MonitoredInput *input = (MonitoredInput *)stream;
    if (cancelled(input->token)) return SZ_ERROR_PROGRESS;
    SRes result = input->originalRead(stream, data, size);
    if (result == SZ_OK && input->token && atomic_load(&input->token->phase) == 1)
        atomic_fetch_add(&input->token->completed, *size);
    return result;
}

static int extract_seven(const char *source, const char *destination, const char *temporaryDirectory,
                         char *outExtension, unsigned capacity, unsigned long long maxBytes,
                         Claw3DSArchiveImportToken *token) {
    MonitoredInput input = {0};
    CLookToRead2 look = {0};
    CSzArEx db;
    int result = 1;
    if (InFile_Open(&input.file.file, source) != 0) return 4;
    FileInStream_CreateVTable(&input.file);
    input.originalRead = input.file.vt.Read;
    input.file.vt.Read = monitored_read;
    input.token = token;
    input.file.wres = 0;
    LookToRead2_CreateVTable(&look, False);
    look.buf = ISzAlloc_Alloc(&alloc, 1u << 18);
    if (!look.buf) { result = 4; goto close_file; }
    look.bufSize = 1u << 18;
    look.realStream = &input.file.vt;
    LookToRead2_INIT(&look);
    CrcGenerateTable();
    SzArEx_Init(&db);
    SRes openStatus = SzArEx_Open(&db, &look.vt, &alloc, &alloc);
    if (openStatus != SZ_OK) {
        result = cancelled(token) ? 5 : openStatus == SZ_ERROR_UNSUPPORTED ? 6 : 1;
        goto close_db;
    }
    if (db.NumFiles > 4096) goto close_db;
    UInt32 selected = 0, found = 0, fallback = 0, unknown = 0;
    UInt64 fallbackSize = 0, secondSize = 0;
    char ext[16], selectedExt[16] = {0};
    for (UInt32 i = 0; i < db.NumFiles; i++) {
        if (SzArEx_IsDir(&db, i)) continue;
        UInt64 size = SzArEx_GetFileSize(&db, i);
        if (!size) continue;
        if (seven_extension(&db, i, ext,
            capacity < sizeof(ext) ? capacity : (unsigned)sizeof(ext))) {
            if (++found > 1) { result = 2; goto close_db; }
            selected = i;
            strcpy(selectedExt, ext);
        } else {
            unknown++;
            if (size > fallbackSize) {
                secondSize = fallbackSize;
                fallbackSize = size;
                fallback = i;
            } else if (size > secondSize) secondSize = size;
        }
    }
    if (!found && fallbackSize >= 4096 && (unknown == 1 ||
        (secondSize <= 1024 * 1024 && fallbackSize > secondSize * 10))) {
        selected = fallback;
        strcpy(selectedExt, "bin");
        found = 1;
    }
    if (!found) { result = 7; goto close_db; }
    UInt64 size = SzArEx_GetFileSize(&db, selected);
    UInt32 folder = db.FileToFolder[selected];
    UInt64 folderSize = folder < db.db.NumFolders ? SzAr_GetFolderUnpackSize(&db.db, folder) : 0;
    if (size == 0 || size > maxBytes || folder >= db.db.NumFolders ||
        folderSize > maxBytes) { result = 3; goto close_db; }
    struct statvfs volume;
    // A single-file folder can become the ROM itself; no second full-size
    // output file is needed. Solid folders with other data still need a copy.
    UInt64 outputSpace = folderSize == size ? 0 : size;
    if (statvfs(temporaryDirectory, &volume) != 0 ||
        folderSize + outputSpace + (128ull << 20) > (UInt64)volume.f_bavail * volume.f_frsize) {
        result = 3;
        goto close_db;
    }
    MappedOutput mapped = { { mapped_alloc, mapped_free }, temporaryDirectory, NULL, 0, {0} };
    UInt32 block = 0xFFFFFFFF;
    Byte *buffer = NULL;
    size_t bufferSize = 0, offset = 0, processed = 0;
    UInt64 compressedSize = 0;
    File_GetLength(&input.file.file, &compressedSize);
    progress(token, 1, 0, compressedSize);
    SRes status = SzArEx_Extract(&db, &look.vt, selected, &block, &buffer,
                                &bufferSize, &offset, &processed, &mapped.api, &alloc);
    if (status == SZ_OK && processed == size && offset <= bufferSize &&
        processed <= bufferSize - offset) {
        // The mapped decoder output already contains the complete game for
        // the usual one-file archive. Rename it rather than writing GB twice.
        if (!cancelled(token) && offset == 0 && processed == bufferSize && mapped.path[0] &&
            rename(mapped.path, destination) == 0) {
            mapped.path[0] = 0;
            progress(token, 2, processed, processed);
            memcpy(outExtension, selectedExt, strlen(selectedExt) + 1);
            result = 0;
        } else if (!cancelled(token)) {
            FILE *out = fopen(destination, "wb");
            if (out) {
                progress(token, 2, 0, processed);
                size_t written = 0;
                while (written < processed && !cancelled(token)) {
                    size_t chunk = processed - written;
                    if (chunk > (1u << 20)) chunk = 1u << 20;
                    size_t next = fwrite(buffer + offset + written, 1, chunk, out);
                    written += next;
                    if (token) atomic_store(&token->completed, written);
                    if (next != chunk) break;
                }
                int closed = fclose(out);
                if (cancelled(token)) result = 5;
                else if (written == processed && closed == 0) {
                    memcpy(outExtension, selectedExt, strlen(selectedExt) + 1);
                    result = 0;
                } else result = 4;
            } else result = 4;
        }
    }
    if (status == SZ_ERROR_MEM) result = 3;
    else if (status == SZ_ERROR_UNSUPPORTED) result = 6;
    else if (cancelled(token)) result = 5;
    ISzAlloc_Free(&mapped.api, buffer);
    if (mapped.mapped) mapped_free(&mapped.api, mapped.mapped);
close_db:
    SzArEx_Free(&db, &alloc);
    ISzAlloc_Free(&alloc, look.buf);
close_file:
    File_Close(&input.file.file);
    return result;
}

int Claw3DSExtractROMArchive(const char *source, const char *destination, const char *temporaryDirectory,
                          char *outExtension, unsigned capacity, unsigned long long maxBytes,
                          Claw3DSArchiveImportToken *token) {
    if (!source || !destination || !temporaryDirectory || !outExtension || capacity < 9 || maxBytes == 0) return 1;
    if (cancelled(token)) return 5;
    outExtension[0] = 0;
    FILE *input = fopen(source, "rb");
    if (!input) return 4;
    unsigned char signature[6] = {0};
    size_t read = fread(signature, 1, sizeof(signature), input);
    fclose(input);
    if (read >= 6 && memcmp(signature, "\x37\x7a\xbc\xaf\x27\x1c", 6) == 0)
        return extract_seven(source, destination, temporaryDirectory,
                             outExtension, capacity, maxBytes, token);
    if (read >= 4 && memcmp(signature, "PK\x03\x04", 4) == 0)
        return extract_zip(source, destination, outExtension, capacity, maxBytes, token);
    return 1;
}

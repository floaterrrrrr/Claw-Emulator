// SPDX-License-Identifier: GPL-3.0-or-later
#include "Native/ROMArchiveImport.h"
#include <assert.h>
#include <dirent.h>
#include <stdio.h>
#include <string.h>

static void check(const char *source, const char *destination, int expected,
                  const char *temporaryDirectory, unsigned long long maxBytes) {
    char ext[16] = {0};
    remove(destination);
    int result = Claw3DSExtractROMArchive(source, destination, temporaryDirectory,
                                       ext, sizeof(ext), maxBytes, NULL);
    assert(result == expected);
    if (expected == 0) {
        assert(strcmp(ext, "gba") == 0);
        FILE *file = fopen(destination, "rb");
        assert(file);
        char bytes[32] = {0};
        assert(fread(bytes, 1, 17, file) == 17);
        assert(memcmp(bytes, "fixture game data", 17) == 0);
        fclose(file);
        remove(destination);
    } else {
        FILE *file = fopen(destination, "rb");
        assert(!file);
    }
}

static void check_no_decoder_files(const char *temporaryDirectory) {
    DIR *directory = opendir(temporaryDirectory);
    assert(directory);
    struct dirent *entry;
    while ((entry = readdir(directory)) != NULL)
        assert(strncmp(entry->d_name, "claw-7z-", 8) != 0);
    closedir(directory);
}

static void check_three_ds(const char *source, const char *destination,
                           const char *temporaryDirectory) {
    char ext[16] = {0};
    remove(destination);
    assert(Claw3DSExtractROMArchive(source, destination, temporaryDirectory,
                                  ext, sizeof(ext), 8192, NULL) == 0);
    assert(strcmp(ext, "3ds") == 0);
    FILE *file = fopen(destination, "rb");
    assert(file);
    assert(fseek(file, 0x100, SEEK_SET) == 0);
    char signature[4];
    assert(fread(signature, 1, sizeof(signature), file) == sizeof(signature));
    assert(memcmp(signature, "NCSD", sizeof(signature)) == 0);
    fclose(file);
    remove(destination);
}

int main(int argc, char **argv) {
    assert(argc == 10);
    check(argv[1], argv[4], 0, argv[7], 1024);
    check(argv[1], argv[4], 3, argv[7], 8);
    check(argv[2], argv[4], 2, argv[7], 1024);
    check(argv[3], argv[4], 0, argv[7], 1024);
    check(argv[6], argv[4], 0, argv[7], 1024);
    char ext[16] = {0};
    assert(Claw3DSExtractROMArchive(argv[5], argv[4], argv[7], ext, sizeof(ext), 8192, NULL) == 0);
    assert(strcmp(ext, "bin") == 0);
    remove(argv[4]);
    check_three_ds(argv[8], argv[4], argv[7]);
    check_three_ds(argv[9], argv[4], argv[7]);
    check_no_decoder_files(argv[7]);
    char invalidDestination[4096];
    int pathLength = snprintf(invalidDestination, sizeof(invalidDestination),
                              "%s/missing/game.3ds", argv[7]);
    assert(pathLength > 0 && (size_t)pathLength < sizeof(invalidDestination));
    assert(Claw3DSExtractROMArchive(argv[8], invalidDestination, argv[7],
                                  ext, sizeof(ext), 8192, NULL) == 4);
    check_no_decoder_files(argv[7]);
    Claw3DSArchiveImportToken *token = Claw3DSArchiveImportTokenCreate();
    assert(token);
    Claw3DSArchiveImportTokenCancel(token);
    assert(Claw3DSExtractROMArchive(argv[1], argv[4], argv[7], ext, sizeof(ext), 8192, token) == 5);
    Claw3DSArchiveImportTokenDestroy(token);
    check_no_decoder_files(argv[7]);
    puts("PASS: .7z/.zip extraction, numeric ROM suffixes, metadata siblings, cancellation, size cap, and temp cleanup");
}

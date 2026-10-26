// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef CLAW_ROM_ARCHIVE_IMPORT_H
#define CLAW_ROM_ARCHIVE_IMPORT_H
#ifdef __cplusplus
extern "C" {
#endif
typedef struct Claw3DSArchiveImportToken Claw3DSArchiveImportToken;
Claw3DSArchiveImportToken *Claw3DSArchiveImportTokenCreate(void);
void Claw3DSArchiveImportTokenCancel(Claw3DSArchiveImportToken *token);
void Claw3DSArchiveImportTokenDestroy(Claw3DSArchiveImportToken *token);
// phase: 0 inspecting, 1 unpacking, 2 writing extracted game.
void Claw3DSArchiveImportTokenProgress(const Claw3DSArchiveImportToken *token,
                                    unsigned long long *completed, unsigned long long *total, int *phase);
// Extract one supported game from .7z or .zip. outExtension is an ASCII suffix.
// 0 success; 1 unsupported/corrupt; 2 multiple games; 3 too large/no space;
// 4 I/O error; 5 cancelled; 6 archive codec unsupported; 7 no recognizable game.
int Claw3DSExtractROMArchive(const char *source, const char *destination, const char *temporaryDirectory,
                          char *outExtension, unsigned capacity, unsigned long long maxBytes,
                          Claw3DSArchiveImportToken *token);
#ifdef __cplusplus
}
#endif
#endif

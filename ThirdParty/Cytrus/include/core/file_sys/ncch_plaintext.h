// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

namespace FileUtil { class IOFileBase; }
struct NCCH_Header;

namespace FileSys {

// Compatibility with decrypted retail NCCH files whose no_crypto flag was not
// updated. Verifies ext-header, ExeFS metadata and every ExeFS file, and the RomFS
// superblock. Reads in bounded chunks; never changes the source ROM or decrypts it.
bool VerifyPlaintextNCCH(FileUtil::IOFileBase& file, const NCCH_Header& header);
} // namespace FileSys

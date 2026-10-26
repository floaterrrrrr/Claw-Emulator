// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct SkinImportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

// Read central-directory entries, not arbitrary paths from the ZIP. Nothing is
// extracted to disk until all metadata and all referenced images are validated.
struct DeltaSkinArchive {
    let files: [String: Data]
    static func safePath(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.contains("\\") && !value.contains(":") &&
        !value.contains("\0") && value.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    init(data: Data) throws {
        guard data.count >= 22, data.count <= 32 * 1024 * 1024 else { throw SkinImportError("This skin file is empty or too large.") }
        func number(_ offset: Int, _ count: Int) throws -> UInt32 {
            guard offset >= 0, offset <= data.count - count else { throw SkinImportError("The skin archive is truncated.") }
            return (0..<count).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
        }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if try number(offset, 4) == 0x06054b50,
               offset + 22 + Int(try number(offset + 20, 2)) == data.count { end = offset; break }
        }
        guard let end, try number(end + 4, 2) == 0, try number(end + 6, 2) == 0 else {
            throw SkinImportError("Choose a standard skin ZIP file.")
        }
        let entries = Int(try number(end + 10, 2)), centralSize = Int(try number(end + 12, 4))
        var cursor = Int(try number(end + 16, 4))
        let centralStart = cursor
        let centralEnd = cursor + centralSize
        guard entries > 0, entries <= 256, try number(end + 8, 2) == UInt32(entries),
              centralEnd == end else { throw SkinImportError("This archive format is not supported.") }
        var result: [String: Data] = [:], names = Set<String>(), total = 0
        for _ in 0..<entries {
            guard try number(cursor, 4) == 0x02014b50 else { throw SkinImportError("The skin archive is damaged.") }
            let flags = try number(cursor + 8, 2), method = try number(cursor + 10, 2)
            let crc = try number(cursor + 16, 4), compressed = Int(try number(cursor + 20, 4))
            let expanded = Int(try number(cursor + 24, 4)), nameSize = Int(try number(cursor + 28, 2))
            let extra = Int(try number(cursor + 30, 2)), comment = Int(try number(cursor + 32, 2))
            let attributes = try number(cursor + 38, 4), local = Int(try number(cursor + 42, 4))
            guard flags & 1 == 0, method == 0 || method == 8, compressed <= 16 * 1024 * 1024,
                  expanded <= 16 * 1024 * 1024, (attributes >> 16) & 0xf000 != 0xa000,
                  cursor + 46 + nameSize + extra + comment <= centralEnd else { throw SkinImportError("This skin uses an unsupported archive feature.") }
            let nameData = data.subdata(in: cursor + 46..<cursor + 46 + nameSize)
            guard let name = String(data: nameData, encoding: .utf8), names.insert(name).inserted else {
                throw SkinImportError("The skin has an invalid or duplicate filename.")
            }
            cursor += 46 + nameSize + extra + comment
            let path = name.hasSuffix("/") ? String(name.dropLast()) : name
            guard Self.safePath(path) else { throw SkinImportError("The skin contains an unsafe filename.") }
            if name.hasSuffix("/") || name.hasPrefix("__MACOSX/") { continue }
            total += expanded
            guard total <= 64 * 1024 * 1024,
                  local >= 0, local + 30 <= centralStart, try number(local, 4) == 0x04034b50,
                  try number(local + 6, 2) == flags, try number(local + 8, 2) == method else {
                throw SkinImportError("The skin archive is damaged or exceeds the size limit.")
            }
            let localName = Int(try number(local + 26, 2)), localExtra = Int(try number(local + 28, 2))
            let start = local + 30 + localName + localExtra
            guard start <= centralStart - compressed,
                  data.subdata(in: local + 30..<local + 30 + localName) == nameData else {
                throw SkinImportError("The skin archive contains conflicting filenames.")
            }
            let input = data.subdata(in: start..<start + compressed)
            var output = Data(count: expanded)
            let valid = output.withUnsafeMutableBytes { destination in input.withUnsafeBytes { source in
                ClawSkinDecode(source.bindMemory(to: UInt8.self).baseAddress, input.count,
                               destination.bindMemory(to: UInt8.self).baseAddress, expanded, UInt16(method), crc)
            } }
            guard valid else { throw SkinImportError("A skin file failed its integrity check.") }
            result[name] = output
        }
        guard cursor == centralEnd else { throw SkinImportError("The skin archive is damaged.") }
        files = result
    }
}

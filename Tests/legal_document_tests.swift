// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main enum LegalTests {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        for name in ["RetroCoreLicenses", "DependencyLicenses", "GPL-3.0", "ThirdPartyNotices", "PrivacyPolicy"] {
            let url = directory.appendingPathComponent(name + ".txt")
            let original = try String(contentsOf: url, encoding: .utf8)
            let sections = try await LegalDocumentLoader.shared.load(url)
            precondition(!sections.isEmpty && sections.allSatisfy { $0.text.count <= 4096 })
            precondition(sections.map(\.text).joined() == original, "A legal notice was dropped or changed")
            precondition(Set(sections.map(\.id)).count == sections.count)
        }
        let unicode = String(repeating: "é🇨🇦\n", count: 5000)
        precondition(LegalDocument.sections(unicode, limit: 3).map(\.text).joined() == unicode)
        precondition(LegalDocument.sections("").isEmpty)
        precondition(LegalDocument.sections("text", limit: 0).isEmpty)
        print("PASS: complete bundled licenses, bounded text layouts, stable sections and Unicode preservation")
    }
}

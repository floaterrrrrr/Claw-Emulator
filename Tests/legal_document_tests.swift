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
        let emulatorURL = directory.appendingPathComponent("RetroCoreLicenses.txt")
        let original = try String(contentsOf: emulatorURL, encoding: .utf8)
        let blocks = try await LegalDocumentLoader.shared.loadEmulatorLicences(emulatorURL)
        precondition(blocks.map(\.rawText).joined() == original,
            "Styled emulator licences must preserve every original character")
        precondition(blocks.filter { $0.kind == .notice }.count == 88)
        precondition(blocks.filter { $0.kind == .source }.count == 14)
        precondition(blocks.first?.kind == .overview)
        precondition(blocks.first(where: { $0.kind == .notice })?.title == "date / LICENSE.txt")
        precondition(blocks.allSatisfy { $0.sections.allSatisfy { $0.text.count <= 4096 } })
        precondition(Set(blocks.map(\.id)).count == blocks.count)
        let cachedBlocks = try await LegalDocumentLoader.shared.loadEmulatorLicences(emulatorURL)
        precondition(cachedBlocks.map(\.rawText) == blocks.map(\.rawText))
        let fixture = "Intro é🇨🇦\n\nexample: https://github.com/example/project/tree/abc123\n\n"
            + "==============\nexample / LICENSE\n==============\n" + unicode
        let fixtureBlocks = EmulatorLicenceBlock.parse(fixture)
        precondition(fixtureBlocks.map(\.rawText).joined() == fixture)
        precondition(fixtureBlocks.map(\.kind) == [.overview, .source, .notice])
        precondition(fixtureBlocks[1].url?.lastPathComponent == "abc123")
        precondition(fixtureBlocks[2].sections.map(\.text).joined() == unicode.trimmingCharacters(in: .newlines))
        precondition(EmulatorLicenceBlock.parse("").isEmpty)
        precondition(EmulatorLicenceBlock.parse("Unstructured notice").first?.rawText == "Unstructured notice")
        print("PASS: complete bundled licenses, bounded text layouts, stable sections and Unicode preservation")
    }
}

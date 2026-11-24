// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct LegalDocumentSection: Identifiable, Sendable {
    let id: Int
    let text: String
}

enum LegalDocument {
    // Bound individual Text layouts without dropping or reformatting notices.
    static func sections(_ text: String, limit: Int = 4096) -> [LegalDocumentSection] {
        guard limit > 0 else { return [] }
        var result: [LegalDocumentSection] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
            result.append(.init(id: result.count, text: String(text[start..<end])))
            start = end
        }
        return result
    }
}

// Presentation boundaries come from the bundled document. Keep each original
// range intact so styling can never discard a notice or its source identity.
struct EmulatorLicenceBlock: Identifiable, Sendable {
    enum Kind: Equatable, Sendable { case overview, source, notice }
    let id: Int
    let kind: Kind
    let title: String
    let url: URL?
    let rawText: String
    let sections: [LegalDocumentSection]

    static func parse(_ text: String) -> [Self] {
        let pattern = #"(?m)^={10,}\n([^\n]+)\n={10,}\n?|^([A-Za-z0-9][A-Za-z0-9-]*): (https://github\.com/[^\s]+/tree/[a-fA-F0-9]+)\n?"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var result: [Self] = []
        func append(kind: Kind, title: String, url: URL? = nil,
                    raw: Substring, body: Substring) {
            result.append(Self(id: result.count, kind: kind, title: title, url: url,
                rawText: String(raw), sections: LegalDocument.sections(
                    String(body).trimmingCharacters(in: .newlines))))
        }
        let first = matches.first.flatMap { Range($0.range, in: text)?.lowerBound } ?? text.endIndex
        if first > text.startIndex {
            let overview = text[..<first]
            let lineEnd = overview.firstIndex(of: "\n") ?? overview.endIndex
            append(kind: .overview, title: String(overview[..<lineEnd]),
                raw: overview, body: overview[lineEnd...])
        }
        for (index, match) in matches.enumerated() {
            guard let range = Range(match.range, in: text) else { continue }
            let end = index + 1 < matches.count
                ? Range(matches[index + 1].range, in: text)!.lowerBound : text.endIndex
            if let heading = Range(match.range(at: 1), in: text) {
                append(kind: .notice, title: String(text[heading]),
                    raw: text[range.lowerBound..<end], body: text[range.upperBound..<end])
            } else if let name = Range(match.range(at: 2), in: text),
                      let address = Range(match.range(at: 3), in: text) {
                append(kind: .source, title: String(text[name]), url: URL(string: String(text[address])),
                    raw: text[range.lowerBound..<end], body: text[range.upperBound..<end])
            }
        }
        return result
    }
}

actor LegalDocumentLoader {
    static let shared = LegalDocumentLoader()
    private var cached: [URL: [LegalDocumentSection]] = [:]
    private var emulatorCached: [URL: [EmulatorLicenceBlock]] = [:]
    func loadEmulatorLicences(_ url: URL) throws -> [EmulatorLicenceBlock] {
        if let value = emulatorCached[url] { return value }
        let value = EmulatorLicenceBlock.parse(try load(url).map(\.text).joined())
        emulatorCached[url] = value
        return value
    }
    func load(_ url: URL) throws -> [LegalDocumentSection] {
        if let value = cached[url] { return value }
        let text = try String(contentsOf: url, encoding: .utf8)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let value = LegalDocument.sections(text)
        cached[url] = value
        return value
    }
}

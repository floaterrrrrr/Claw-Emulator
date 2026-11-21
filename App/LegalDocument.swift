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

actor LegalDocumentLoader {
    static let shared = LegalDocumentLoader()
    private var cached: [URL: [LegalDocumentSection]] = [:]
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

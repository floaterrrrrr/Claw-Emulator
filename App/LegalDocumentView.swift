// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct LegalDocumentView: View {
    let title: String
    let resource: String

    @State private var sections: [LegalDocumentSection] = []
    @State private var failure: String?

    var body: some View {
        ConsoleSettingsPage(title: title, subtitle: "", symbol: "doc.text") {
            if let failure { Text(failure).accessibilityIdentifier("legalDocumentError") }
            else if sections.isEmpty { ProgressView("Loading document…") }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sections) { section in
                    Text(verbatim: section.text)
                        .font(.subheadline).lineSpacing(4).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.accessibilityIdentifier("legalDocumentContent")
        }.task(id: resource) {
            sections = []; failure = nil
            guard let url = Bundle.main.url(forResource: resource, withExtension: "txt")
                ?? Bundle.main.url(forResource: resource, withExtension: "txt", subdirectory: "Legal") else {
                failure = "This document is missing. Please contact support from Settings."
                return
            }
            do {
                let value = try await LegalDocumentLoader.shared.load(url)
                guard !Task.isCancelled else { return }
                sections = value
            } catch {
                guard !Task.isCancelled else { return }
                failure = "This document could not be loaded. Please reopen this page or contact support from Settings."
            }
        }
    }
}

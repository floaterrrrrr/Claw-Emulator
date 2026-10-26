// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct LegalDocumentView: View {
    let title: String
    let resource: String

    private var document: String {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "This document could not be loaded. Please see the source and support link in Settings."
        }
        return text
    }

    var body: some View {
        ConsoleSettingsPage(title: title, subtitle: "", symbol: "doc.text") {
            Text(document)
                .font(.subheadline).lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }
}

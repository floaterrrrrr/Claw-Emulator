// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct LegalDocumentView: View {
    let title: String
    let resource: String

    @State private var sections: [LegalDocumentSection] = []
    @State private var licenceBlocks: [EmulatorLicenceBlock] = []
    @State private var failure: String?

    private var isEmulatorLicences: Bool { resource == "RetroCoreLicenses" }

    var body: some View {
        ConsoleSettingsPage(title: title, subtitle: "", symbol: "doc.text") {
            if let failure { Text(failure).accessibilityIdentifier("legalDocumentError") }
            else if sections.isEmpty && licenceBlocks.isEmpty { ProgressView("Loading document…") }
            if isEmulatorLicences {
                EmulatorLicenceCards(blocks: licenceBlocks)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        Text(verbatim: section.text)
                            .font(.subheadline).lineSpacing(4).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.accessibilityIdentifier("legalDocumentContent")
            }
        }.task(id: resource) {
            sections = []; licenceBlocks = []; failure = nil
            guard let url = Bundle.main.url(forResource: resource, withExtension: "txt")
                ?? Bundle.main.url(forResource: resource, withExtension: "txt", subdirectory: "Legal") else {
                failure = "This document is missing. Please contact support from Settings."
                return
            }
            do {
                if isEmulatorLicences {
                    let value = try await LegalDocumentLoader.shared.loadEmulatorLicences(url)
                    guard !Task.isCancelled else { return }
                    licenceBlocks = value
                } else {
                    let value = try await LegalDocumentLoader.shared.load(url)
                    guard !Task.isCancelled else { return }
                    sections = value
                }
            } catch {
                guard !Task.isCancelled else { return }
                failure = "This document could not be loaded. Please reopen this page or contact support from Settings."
            }
        }
    }
}

private struct EmulatorLicenceCards: View {
    let blocks: [EmulatorLicenceBlock]

    var body: some View {
        let firstNotice = blocks.first(where: { $0.kind == .notice })?.id
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(blocks) { block in
                EmulatorLicenceCard(block: block, initiallyExpanded: block.id == firstNotice)
            }
        }.accessibilityIdentifier("legalDocumentContent")
    }
}

#if DEBUG
private struct EmulatorLicencesPreview: PreviewProvider {
    static var previews: some View {
        LegalDocumentView(title: "Emulator licences", resource: "RetroCoreLicenses")
            .modifier(ClawStyle())
    }
}
#endif

private struct EmulatorLicenceCard: View {
    let block: EmulatorLicenceBlock
    @State private var expanded: Bool
    @Environment(\.clawAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(block: EmulatorLicenceBlock, initiallyExpanded: Bool) {
        self.block = block
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch block.kind {
            case .overview:
                badge("Cores & dependencies", symbol: "square.stack.3d.up")
                Text(verbatim: block.title).font(.headline)
                    .accessibilityAddTraits(.isHeader)
                documentText
            case .source:
                source
                if !block.sections.isEmpty { documentText }
            case .notice:
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "doc.text").foregroundStyle(accent)
                            .frame(width: 36, height: 40)
                            .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: component).font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(verbatim: filename).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(block.title)
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                    .accessibilityHint(expanded ? "Hide licence text" : "Read full licence text")
                    .accessibilityIdentifier("emulatorLicence-\(block.id)")
                if expanded {
                    Divider()
                    documentText
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .consolePanel()
    }

    private var component: String {
        block.title.components(separatedBy: " / ").first ?? block.title
    }
    private var filename: String {
        let parts = block.title.components(separatedBy: " / ")
        return parts.count > 1 ? parts.dropFirst().joined(separator: " / ") : "Full licence notice"
    }

    private var source: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(verbatim: block.title).font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                badge("Source", symbol: "chevron.left.forwardslash.chevron.right")
            }
            if let url = block.url {
                Link(destination: url) {
                    HStack(alignment: .center, spacing: 10) {
                        Text(verbatim: repositoryAddress(url)).font(.footnote.weight(.medium))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right").font(.caption.weight(.semibold))
                    }.foregroundStyle(accent).padding(.horizontal, 12).padding(.vertical, 10)
                        .frame(minHeight: 44)
                        .background(ClawPalette.subtleFill, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain)
                    .accessibilityLabel("Open \(block.title) source on GitHub")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Revision").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    Text(verbatim: url.lastPathComponent).font(.caption.monospaced())
                        .foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func repositoryAddress(_ url: URL) -> String {
        let path = url.path.components(separatedBy: "/tree/").first ?? url.path
        return (url.host ?? "github.com") + path
    }

    private func badge(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.caption2.weight(.medium))
            .foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 6)
            .background(ClawPalette.subtleFill, in: Capsule())
    }

    private var documentText: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(block.sections) { section in
                Text(verbatim: section.text).font(.subheadline).lineSpacing(5)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

import SwiftUI
import MarkdownUI

struct MarkdownResponse: View {
    let text: String
    let fontSize: Double
    var sources: [Source] = []
    @State private var selectedSource: Source?
    private let ink = DialogPalette.ink
    private let accent = DialogPalette.accent

    var body: some View {
        Markdown(CitationMarkdown.render(text, references: Set(sources.map(\.ref))))
            .markdownTheme(theme)
            .tint(accent)
            .markdownImageProvider(.asset)
            .markdownInlineImageProvider(.asset)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "dialog-source" {
                    if let ref = url.host.flatMap(Int.init), let source = sources.first(where: { $0.ref == ref }) { selectedSource = source }
                    return .handled
                }
                return .systemAction
            })
            .sheet(item: $selectedSource) { source in SourceSnippetView(source: source) }
    }

    private var theme: Theme {
        Theme.gitHub
            .text {
                FontSize(fontSize)
                ForegroundColor(ink)
                BackgroundColor(nil)
            }
            .link { ForegroundColor(accent); UnderlineStyle(.single) }
            .strong { FontWeight(.semibold); ForegroundColor(.white) }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.88))
                ForegroundColor(ink)
                BackgroundColor(Color.white.opacity(0.08))
            }
            .codeBlock { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .relativeLineSpacing(.em(0.25))
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(0.86))
                            ForegroundColor(ink)
                            BackgroundColor(nil)
                        }
                        .padding(14)
                }
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.28)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DialogPalette.line))
                .markdownMargin(top: .em(0), bottom: .em(0.8))
            }
            .blockquote { configuration in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2).fill(accent.opacity(0.7)).frame(width: 3)
                    configuration.label
                        .markdownTextStyle { ForegroundColor(DialogPalette.muted) }
                        .padding(.leading, 12)
                }
                .fixedSize(horizontal: false, vertical: true)
                .markdownMargin(top: .em(0), bottom: .em(0.8))
            }
            .paragraph { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.22))
                    .markdownMargin(top: .em(0), bottom: .em(0.65))
            }
            .table { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .markdownTableBorderStyle(.init(color: DialogPalette.line))
                        .markdownTableBackgroundStyle(.alternatingRows(Color.white.opacity(0.03), Color.white.opacity(0.07)))
                }.markdownMargin(top: .em(0), bottom: .em(0.65))
            }
    }
}

private struct SourceSnippetView: View {
    let source: Source
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(source.name).font(.system(size: 14, weight: .medium)).textSelection(.enabled)
                    Text("Источник [\(source.ref)] · строка \(source.line)").font(.system(size: 11)).foregroundStyle(DialogPalette.muted)
                }
                Spacer()
                DialogIconButton(symbol: "xmark", label: "Закрыть источник", glass: true) { dismiss() }
            }
            ScrollView { Text(source.text).font(.system(size: 13, design: .monospaced)).foregroundStyle(DialogPalette.ink.opacity(0.9)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16) }
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.28)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(DialogPalette.line))
        }
        .padding(26).frame(width: 640, height: 420)
        .dialogSheet()
    }
}

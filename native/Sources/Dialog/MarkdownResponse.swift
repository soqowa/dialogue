import SwiftUI
import MarkdownUI

struct MarkdownResponse: View {
    let text: String
    let fontSize: Double
    var sources: [Source] = []
    @State private var selectedSource: Source?
    private let ink = Color(red: 0.15, green: 0.19, blue: 0.15)
    private let sage = Color(red: 0.33, green: 0.44, blue: 0.27)
    private let canvas = Color(red: 0.97, green: 0.98, blue: 0.96)

    var body: some View {
        Markdown(CitationMarkdown.render(text, references: Set(sources.map(\.ref))))
            .markdownTheme(theme)
            .tint(sage)
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
            .link { ForegroundColor(sage); UnderlineStyle(.single) }
            .paragraph { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.22))
                    .markdownMargin(top: .em(0), bottom: .em(0.65))
            }
            .table { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .markdownTableBorderStyle(.init(color: sage.opacity(0.2)))
                        .markdownTableBackgroundStyle(.alternatingRows(.white, canvas))
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
                    Text("Источник [\(source.ref)] · строка \(source.line)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                DialogIconButton(symbol: "xmark", label: "Закрыть источник") { dismiss() }
            }
            Divider()
            ScrollView { Text(source.text).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .padding(26).frame(width: 640, height: 420)
        .background(Color(red: 0.97, green: 0.98, blue: 0.96))
    }
}

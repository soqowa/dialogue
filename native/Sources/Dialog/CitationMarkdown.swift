import Foundation
import cmark_gfm
import cmark_gfm_extensions

enum CitationMarkdown {
    private static let citation = try! NSRegularExpression(pattern: #"\[(\d+)\]"#)

    /// Change citation text nodes only. Code, existing links and image labels stay intact.
    static func render(_ markdown: String, references: Set<Int>) -> String {
        guard !references.isEmpty, markdown.contains("[") else { return markdown }
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return markdown }
        defer { cmark_parser_free(parser) }
        for name in ["autolink", "strikethrough", "tagfilter", "tasklist", "table"] {
            if let syntax = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, syntax) }
        }
        cmark_parser_feed(parser, markdown, markdown.utf8.count)
        guard let document = cmark_parser_finish(parser) else { return markdown }
        defer { cmark_node_free(document) }
        rewrite(document, references: references)
        guard let result = cmark_render_commonmark(document, CMARK_OPT_DEFAULT, 0) else { return markdown }
        defer { free(result) }
        return String(cString: result)
    }

    private static func rewrite(_ node: UnsafeMutablePointer<cmark_node>, references: Set<Int>) {
        let type = cmark_node_get_type(node)
        if type == CMARK_NODE_LINK || type == CMARK_NODE_IMAGE { return }
        if type == CMARK_NODE_TEXT, let literal = cmark_node_get_literal(node) {
            let text = String(cString: literal) as NSString
            let matches = citation.matches(in: text as String, range: NSRange(location: 0, length: text.length)).filter {
                Int(text.substring(with: $0.range(at: 1))).map(references.contains) ?? false
            }
            guard !matches.isEmpty else { return }
            var offset = 0
            for match in matches {
                insertText(text.substring(with: NSRange(location: offset, length: match.range.location - offset)), before: node)
                let number = text.substring(with: match.range(at: 1))
                if let link = cmark_node_new(CMARK_NODE_LINK), let label = cmark_node_new(CMARK_NODE_TEXT) {
                    cmark_node_set_url(link, "dialog-source://\(number)")
                    cmark_node_set_literal(label, "[\(number)]")
                    cmark_node_append_child(link, label)
                    cmark_node_insert_before(node, link)
                }
                offset = NSMaxRange(match.range)
            }
            insertText(text.substring(from: offset), before: node)
            cmark_node_unlink(node)
            cmark_node_free(node)
            return
        }
        var child = cmark_node_first_child(node)
        while let current = child {
            child = cmark_node_next(current)
            rewrite(current, references: references)
        }
    }

    private static func insertText(_ text: String, before node: UnsafeMutablePointer<cmark_node>) {
        guard !text.isEmpty, let inserted = cmark_node_new(CMARK_NODE_TEXT) else { return }
        cmark_node_set_literal(inserted, text)
        cmark_node_insert_before(node, inserted)
    }
}

import XCTest
import MarkdownUI
import SwiftUI
import AppKit
@testable import Dialog

final class MarkdownTests: XCTestCase {
    @MainActor func testFontSizeChangesTheRenderedLayoutInBothDirections() {
        _ = NSApplication.shared
        let text = """
        **Очередь** обрабатывает сообщения в порядке поступления. Эта строка достаточно длинная, чтобы при изменении размера шрифта переноситься по-разному.

        - Первый элемент списка
        - Второй элемент списка

        `let value = queue.first`
        """
        func content(_ size: Double) -> some View {
            MarkdownResponse(text: text, fontSize: size)
                .frame(width: 320)
                .fixedSize(horizontal: false, vertical: true)
        }
        let host = NSHostingView(rootView: content(10))
        let small = host.fittingSize.height
        host.rootView = content(30)
        host.layoutSubtreeIfNeeded()
        let large = host.fittingSize.height
        XCTAssertGreaterThan(large, small * 2, "The Markdown theme must use the selected font size, not a fixed 16pt size")
        host.rootView = content(10)
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThan(host.fittingSize.height, large / 2)
    }

    func testAdjacentCitationsKeepTheirOwnDestinations() {
        let result = CitationMarkdown.render("Ответ по материалам [1][2], неизвестный источник [99].", references: [1, 2])
        let html = MarkdownContent(result).renderHTML()
        XCTAssertTrue(html.contains(#"href="dialog-source://1">[1]</a>"#))
        XCTAssertTrue(html.contains(#"href="dialog-source://2">[2]</a>"#))
        XCTAssertFalse(html.contains("dialog-source://99"))
        XCTAssertTrue(html.contains("[99]"))
    }

    func testCodeAndExistingLinksRemainIntact() {
        let markdown = """
        `values[1][2]` и [ссылка [1]](https://example.com/docs?q=1).

        ```swift
        let item = values[1]
        ```

            indented[2]

        Обычная ссылка на источник [1].
        """
        let html = MarkdownContent(CitationMarkdown.render(markdown, references: [1, 2])).renderHTML()
        XCTAssertTrue(html.contains("<code>values[1][2]</code>"))
        XCTAssertTrue(html.contains("let item = values[1]"))
        XCTAssertTrue(html.contains("indented[2]"))
        XCTAssertTrue(html.contains(#"href="https://example.com/docs?q=1">ссылка [1]</a>"#))
        XCTAssertEqual(html.components(separatedBy: "dialog-source://").count - 1, 1)
    }

    func testMarkdownStructureSurvivesCitationsAndStreaming() {
        let markdown = """
        ## Очередь

        **FIFO** и *порядок* [1].

        - Первый пункт
        - Второй пункт

        | Сценарий | Результат |
        | --- | --- |
        | Лимит | Отказ [1] |
        """
        let html = MarkdownContent(CitationMarkdown.render(markdown, references: [1])).renderHTML()
        for tag in ["<h2>", "<strong>FIFO</strong>", "<em>порядок</em>", "<ul>", "<table>"] { XCTAssertTrue(html.contains(tag), tag) }
        for end in markdown.indices {
            let partial = String(markdown[..<end])
            let result = CitationMarkdown.render(partial, references: [1])
            XCTAssertFalse(result.contains("dialog-source://99"))
        }
        let partial = CitationMarkdown.render("Незавершённая ссылка [1", references: [1])
        XCTAssertEqual(MarkdownContent(partial).renderPlainText(), "Незавершённая ссылка [1")
    }
}

import SwiftUI

private struct HistoryLine: Identifiable {
    let id: String; let seq: Int; let speaker: String; let text: String
    var sources: [Source]? = nil
}

struct HistoryView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    private let tint = Color(red: 0.33, green: 0.44, blue: 0.27)
    private var lines: [HistoryLine] {
        guard let snapshot = app.historyPreview, snapshot.id == selection else { return [] }
        var result = snapshot.transcript.map { HistoryLine(id: $0.id, seq: $0.seq ?? 0, speaker: $0.source == "mic" ? "Я" : "Собеседник", text: $0.text) }
        for exchange in snapshot.exchanges {
            result.append(HistoryLine(id: exchange.id + "-q", seq: exchange.seq, speaker: "Вопрос помощнику", text: exchange.question))
            if !exchange.text.isEmpty { result.append(HistoryLine(id: exchange.id, seq: exchange.answerSeq ?? exchange.seq, speaker: "Помощник", text: exchange.text, sources: exchange.sources)) }
        }
        return result.sorted { $0.seq < $1.seq }
    }
    var body: some View {
        VStack(spacing: 18) {
            HStack { Text("История").font(.system(size: 24, weight: .medium)); Spacer(); DialogIconButton(symbol: "xmark", label: "Закрыть историю") { dismiss() } }
            HStack(spacing: 18) {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(app.sessions) { session in
                            Button { selection = session.id; Task { await app.previewSession(session.id) } } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(session.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                    Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                            }.buttonStyle(DialogButtonStyle(.row, selected: selection == session.id))
                        }
                    }
                }.frame(width: 210)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(lines) { line in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(line.speaker).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
                                if let sources = line.sources { MarkdownResponse(text: line.text, fontSize: 13, sources: sources) }
                                else { Text(line.text).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(8)
                }.frame(maxWidth: .infinity)
            }.frame(maxHeight: .infinity)
            Divider()
            HStack { Spacer(); Button("Продолжить разговор") { if let selection { Task { await app.resumeSession(selection) } } }.buttonStyle(DialogButtonStyle(.primary)).disabled(selection == nil) }
        }.padding(26).frame(width: 800, height: 600)
            .background(Color(red: 0.97, green: 0.98, blue: 0.96))
            .task { await app.loadSessions(); selection = app.preferences.sessionID ?? app.sessions.first?.id; if let selection { await app.previewSession(selection) } }
    }
}

import SwiftUI

private let ink = DialogPalette.ink
private let accent = DialogPalette.accent
private let muted = DialogPalette.muted
private let lineColor = DialogPalette.line
private let panelShape = RoundedRectangle(cornerRadius: 24, style: .continuous)

struct ContentView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sidebarVisible = true

    var body: some View {
        ZStack {
            DialogBackdrop()
            HStack(spacing: 12) {
                if sidebarVisible {
                    SidebarView().frame(width: 232)
                        .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
                }
                VStack(alignment: .leading, spacing: 14) {
                    sessionBar
                    ConversationSplitView()
                    if !app.running && !app.starting {
                        questionField.transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .disabled(app.projectSwitching)
            }
            // The top safe area is the hidden title bar with the window buttons.
            .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 2)
        }
        .foregroundStyle(ink).frame(minWidth: 1050, minHeight: 720)
        .tint(accent)
        .buttonStyle(DialogButtonStyle())
        .task { await app.boot() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in app.refreshAnswerShortcutAccess(); app.refreshMicrophones() }
        .onChange(of: app.running) { _, running in
            if running { setSidebarVisible(false) }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: app.running || app.starting)
        .sheet(isPresented: $app.showSettings) { SettingsView() }
        .sheet(isPresented: $app.showMaterials) { MaterialsView() }
        .sheet(isPresented: $app.showHistory) { HistoryView() }
        .sheet(isPresented: $app.showProjectEditor) { ProjectEditorView() }
        .alert("Диалог", isPresented: Binding(get: { app.message != nil }, set: { if !$0 { app.message = nil } })) { Button("Понятно", role: .cancel) { app.message = nil } } message: { Text(app.message ?? "") }
    }
    private var sessionBar: some View {
        GlassGroup(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    listeningControls
                    Spacer(minLength: 12)
                    responseControls
                    sessionActions
                }
                VStack(spacing: 10) {
                    HStack(spacing: 10) { listeningControls; Spacer(minLength: 8); sessionActions }
                    HStack(spacing: 10) { responseControls; Spacer(minLength: 0) }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
    private var listeningControls: some View {
        HStack(spacing: 10) {
            DialogIconButton(symbol: "sidebar.left", label: sidebarVisible ? "Скрыть боковую панель" : "Показать боковую панель", glass: true) {
                setSidebarVisible(!sidebarVisible)
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .accessibilityIdentifier("session.sidebar")
            Button { Task { await app.toggleCapture() } } label: {
                Label(app.starting ? "Подключаю…" : app.running ? "Остановить" : "Слушать", systemImage: app.running ? "stop.fill" : "waveform")
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    .symbolEffect(.variableColor.iterative, isActive: app.starting)
                    .contentTransition(.symbolEffect(.replace))
            }.buttonStyle(DialogButtonStyle(.primary, tint: app.running ? DialogPalette.danger : accent)).disabled(app.starting)
                .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: app.running)
                .accessibilityIdentifier("session.listen")
            ProjectMenu()
            if !app.running && app.speechState != "ready" {
                Circle().fill(.orange).frame(width: 7, height: 7).shadow(color: .orange.opacity(0.6), radius: 4)
                    .help(app.speechState == "error" ? "Распознавание недоступно" : "Подготовка распознавания…")
            }
            if let date = app.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(date)))
                    HStack(spacing: 7) {
                        Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(DialogPalette.danger)
                            .shadow(color: DialogPalette.danger.opacity(0.8), radius: 4)
                            .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                        Text(elapsed(TimeInterval(seconds))).monospacedDigit().font(.system(size: 11, weight: .medium))
                            .contentTransition(.numericText(countsDown: false))
                            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: seconds)
                    }
                    .padding(.horizontal, 13).frame(height: DialogPalette.controlHeight)
                    .liquidGlass(Capsule())
                }
                .transition(reduceMotion ? .opacity : .scale(scale: 0.85, anchor: .leading).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: app.startedAt == nil)
        .fixedSize()
    }
    private var responseControls: some View {
        HStack(spacing: 10) {
            DialogAnswerModePicker(automatic: $app.preferences.auto)
            Button { Task { await app.answerFromConversation() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold)).foregroundStyle(DialogPalette.icon)
                    Text(app.contextAnswerPending ? "Распознаю…" : "Ответить").lineLimit(1)
                    Text(app.answerShortcut.display).foregroundStyle(muted).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.white.opacity(0.08)))
                }.font(.system(size: 11, weight: .medium))
            }.buttonStyle(DialogButtonStyle()).disabled(!app.canAnswerFromConversation).accessibilityIdentifier("answer.context")
                .help("Ответить по текущему диалогу · \(app.answerShortcut.display). Работает и в других приложениях.")
        }.fixedSize()
    }
    private var sessionActions: some View {
        HStack(spacing: 8) {
            DialogIconButton(symbol: "square.and.arrow.down", label: "Сохранить расшифровку и ответы", glass: true) { app.exportSession() }
            DialogIconButton(symbol: "arrow.counterclockwise", label: "Новый разговор", glass: true) { Task { await app.newSession() } }
            DialogIconButton(symbol: "gearshape", label: "Настройки", glass: true) { app.settingsTab = 1; app.showSettings = true }
        }.fixedSize()
    }
    private func setSidebarVisible(_ visible: Bool) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.26)) { sidebarVisible = visible }
    }
    private var questionField: some View {
        let empty = app.manualQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 12) {
            Image(systemName: "text.cursor").font(.system(size: 13)).foregroundStyle(muted)
            TextField("Или введи запрос, чтобы проверить ответ…", text: $app.manualQuestion).textFieldStyle(.plain).font(.system(size: 13)).onSubmit { app.ask() }
            Button { app.ask() } label: {
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(empty ? Color.white.opacity(0.45) : Color.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(empty ? Color.white.opacity(0.10) : accent))
            }
            .buttonStyle(DialogButtonStyle(.icon)).disabled(empty)
            .scaleEffect(empty ? 0.92 : 1)
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: empty)
            .help("Получить ответ").accessibilityLabel("Получить ответ")
        }
        .padding(.leading, 18).padding(.trailing, 4)
        .frame(height: 46)
        .liquidGlass(Capsule())
    }
    private func elapsed(_ time: TimeInterval) -> String { let seconds = max(0, Int(time)); return String(format: "%02d:%02d", seconds / 60, seconds % 60) }
}

struct SidebarView: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(systemName: "quote.bubble.fill").font(.system(size: 22)).foregroundStyle(DialogPalette.icon)
                Text("диалог").font(.system(size: 26, weight: .semibold)).tracking(-1.1)
            }.padding(.horizontal, 12).padding(.top, 20).padding(.bottom, 20)
            Button { app.showMaterials = false; app.showSettings = false } label: { Label("Разговор", systemImage: "waveform.circle.fill").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(DialogButtonStyle(.row, selected: true)).font(.system(size: 13, weight: .medium))
            Button { app.showMaterials = true } label: {
                HStack {
                    Label("Материалы", systemImage: "square.3.layers.3d")
                    Spacer()
                    Text("\(app.materialGroups.count)").font(.system(size: 10, weight: .medium)).monospacedDigit()
                        .contentTransition(.numericText()).animation(.snappy, value: app.materialGroups.count)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(.white.opacity(0.10)))
                }
            }.buttonStyle(DialogButtonStyle(.row)).font(.system(size: 12))
            Button { app.settingsTab = 0; app.showSettings = true } label: { Label("Манера ответа", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(DialogButtonStyle(.row)).font(.system(size: 12))
            Button { app.openHistory() } label: { Label("История", systemImage: "clock").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(DialogButtonStyle(.row)).font(.system(size: 12))
            GlassDivider().padding(.vertical, 16).padding(.horizontal, 12)
            if app.materials.isEmpty {
                Spacer(minLength: 0)
            } else {
                Text("В базе").font(.system(size: 10, weight: .semibold)).foregroundStyle(muted).textCase(.uppercase).tracking(0.6).padding(.horizontal, 12).padding(.bottom, 6)
                ScrollView { LazyVStack(alignment: .leading, spacing: 4) { ForEach(app.materialGroups) { group in MaterialGroupRow(group: group, compact: true) } } }
                    .frame(maxHeight: .infinity)
            }
            // Pinned to the bottom of the sidebar so it never floats mid-panel.
            Button { app.chooseFiles() } label: { Label(app.uploading ? app.uploadProgress : "Добавить материалы", systemImage: "plus").font(.system(size: 11, weight: .medium)).foregroundStyle(ink.opacity(0.8)).frame(maxWidth: .infinity).padding(.vertical, 11) }.buttonStyle(DialogButtonStyle(.card)).disabled(app.uploading)
                .padding(.top, 12)
        }
        .padding(.horizontal, 12).padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .liquidGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .disabled(app.projectSwitching)
    }
}

struct AnswerView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false
    @State private var copyFeedback: Task<Void, Never>?
    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Подсказка для ответа", symbol: "sparkles") {
                Button("A−") { app.preferences.fontSize = max(10, app.preferences.fontSize - 2) }.font(.system(size: 12, weight: .medium)).buttonStyle(DialogButtonStyle(.icon)).disabled(app.preferences.fontSize <= 10).help("Уменьшить шрифт · \(Int(app.preferences.fontSize)) пт")
                Button("A+") { app.preferences.fontSize = min(40, app.preferences.fontSize + 2) }.font(.system(size: 12, weight: .medium)).buttonStyle(DialogButtonStyle(.icon)).disabled(app.preferences.fontSize >= 40).help("Увеличить шрифт · \(Int(app.preferences.fontSize)) пт")
                DialogIconButton(symbol: copied ? "checkmark" : "doc.on.doc", label: copied ? "Ответ скопирован" : "Скопировать весь ответ") {
                    copyFeedback?.cancel()
                    let success = app.copyAnswer()
                    withAnimation(.snappy) { copied = success }
                    if success {
                        copyFeedback = Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            if !Task.isCancelled { withAnimation(.snappy) { copied = false } }
                        }
                    }
                }.disabled(app.answer.isEmpty)
            }
            GlassDivider()
            ScrollView {
                if app.question.isEmpty { onboarding.transition(.opacity) }
                else {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "quote.opening").font(.system(size: 11, weight: .bold)).foregroundStyle(muted).padding(.top, 2)
                            Text(app.question).font(.system(size: 13)).foregroundStyle(muted).textSelection(.enabled)
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.05)))
                        if app.answer.isEmpty && app.generating {
                            TypingIndicator(label: "Формулирую").transition(.opacity)
                        } else {
                            MarkdownResponse(text: app.answer, fontSize: app.preferences.fontSize, sources: app.sources)
                                .transition(.opacity)
                            if app.generating { TypingIndicator().transition(.opacity) }
                        }
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    .id(app.question)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 10)))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: app.question)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: app.answer.isEmpty)
            if !app.question.isEmpty {
                GlassDivider()
                HStack {
                    if app.generating {
                        Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(accent)
                            .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                    }
                    Text(app.answerStatus).font(.system(size: 10))
                    Spacer()
                    if app.generating { Button("Остановить") { app.cancelAnswer() }.buttonStyle(DialogButtonStyle(.row)).fixedSize().font(.system(size: 10, weight: .medium)) }
                }.foregroundStyle(muted).padding(.horizontal, 16).frame(minHeight: 44)
            }
        }
        .liquidGlass(panelShape)
        .onChange(of: app.answer) { _, _ in copied = false }
        .onDisappear { copyFeedback?.cancel() }
    }
    private var onboarding: some View {
        VStack(spacing: 16) {
            OnboardingEmblem().padding(.top, 28).padding(.bottom, 8)
            Text("Ты слушаешь.\nОтвет уже рядом.").font(.system(size: 30, weight: .semibold)).tracking(-0.9).multilineTextAlignment(.center)
            Text("Подключи звонок, и здесь появится понятный\nответ с опорой на твои материалы.").font(.system(size: 12)).foregroundStyle(muted).lineSpacing(6).multilineTextAlignment(.center)
            VStack(spacing: 4) {
                step("1", "Добавь свои материалы", "Конспекты, PDF, документы или код", symbol: "square.3.layers.3d") { app.showMaterials = true }
                step("2", "Настрой манеру ответа", "Кратко, подробно, своими словами", symbol: "slider.horizontal.3") { app.settingsTab = 0; app.showSettings = true }
                step("3", "Начни слушать компьютер", "Системный звук и микрофон", symbol: "waveform") { Task { await app.toggleCapture() } }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(lineColor))
            .padding(.top, 14).frame(maxWidth: 380)
        }.padding(25).frame(maxWidth: .infinity)
    }
    private func step(_ number: String, _ title: String, _ subtitle: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(DialogPalette.icon)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.07)))
                VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 12, weight: .medium)); Text(subtitle).font(.system(size: 10)).foregroundStyle(muted) }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(muted)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(DialogButtonStyle(.row))
        .accessibilityIdentifier("onboarding.0\(number)")
    }
}

private struct OnboardingEmblem: View {
    var body: some View {
        ZStack {
            Circle().fill(accent).frame(width: 60, height: 60).blur(radius: 28).opacity(0.45)
            Circle().stroke(.white.opacity(0.08), lineWidth: 1).frame(width: 96, height: 96)
            Circle().trim(from: 0.05, to: 0.30).stroke(accent.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, lineCap: .round)).frame(width: 96, height: 96).rotationEffect(.degrees(-30))
            Image(systemName: "sparkles").font(.system(size: 26, weight: .light)).foregroundStyle(ink)
                .frame(width: 66, height: 66)
                .liquidGlass(Circle())
        }.frame(width: 100, height: 100).accessibilityHidden(true)
    }
}

/// Three dots that ripple while an answer is being written.
private struct TypingIndicator: View {
    var label: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "ellipsis").font(.system(size: 18, weight: .bold)).foregroundStyle(accent)
                .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating, isActive: !reduceMotion)
            if let label { Text(label).font(.system(size: 13)).foregroundStyle(muted) }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(label ?? "Ответ пишется")
    }
}

private struct PanelHeader<Actions: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let actions: Actions

    init(_ title: String, symbol: String, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.symbol = symbol
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(DialogPalette.icon)
            Text(title).font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 8)
            actions
        }
        .foregroundStyle(ink)
        .padding(.leading, 20).padding(.trailing, 12)
        .frame(height: 52)
    }
}

struct TranscriptView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Диалог", symbol: "text.bubble") {
                if app.running {
                    HStack(spacing: 6) {
                        Circle().fill(DialogPalette.danger).frame(width: 6, height: 6).shadow(color: DialogPalette.danger, radius: 3)
                        Text("Запись").font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
                    }.padding(.trailing, 8).accessibilityElement(children: .ignore).accessibilityLabel("Запись")
                }
            }
            GlassDivider()
            VStack(spacing: 10) {
                sourceRow("Собеседник", icon: "speaker.wave.2.fill", level: app.remoteLevel)
                HStack {
                    Image(systemName: "mic.fill").font(.system(size: 11)).frame(width: 22).foregroundStyle(accent)
                    Text("Я").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Toggle("Микрофон", isOn: $app.preferences.microphone).labelsHidden().toggleStyle(.switch).controlSize(.mini).disabled(app.running || app.starting)
                    Meter(level: app.micLevel)
                }.help(app.activeMicrophoneName ?? "Микрофон для своего голоса выбирается в настройках")
                if let issue = app.microphoneIssue { Label(issue, systemImage: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading) }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.045)))
            .padding(12)
            GlassDivider()
            if app.transcript.isEmpty {
                VStack(spacing: 14) {
                    Spacer()
                    HStack(spacing: 4) {
                        ForEach(0..<9) { index in
                            Capsule().fill(accent.opacity(0.35))
                                .frame(width: 3, height: [10.0, 18, 25, 18, 32, 25, 10, 18, 25][index])
                        }
                    }.frame(height: 34).accessibilityHidden(true)
                    Text("Здесь будет ваш диалог").font(.system(size: 12, weight: .medium)).foregroundStyle(ink.opacity(0.75)).padding(.top, 8)
                    Text("Два источника звука.\nКаждая реплика на своём месте.").font(.system(size: 11)).foregroundStyle(muted.opacity(0.85)).multilineTextAlignment(.center).lineSpacing(6)
                    Spacer()
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) { ForEach(app.transcript) { item in TranscriptRow(item: item).id(item.id) } }
                            .padding(16)
                            .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: app.transcript.count)
                    }
                    .onChange(of: app.transcript.last?.text) { _, _ in
                        guard let id = app.transcript.last?.id else { return }
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
            GlassDivider()
            Label("В наушниках распознавание точнее", systemImage: "headphones").font(.system(size: 9)).foregroundStyle(muted).frame(maxWidth: .infinity).frame(height: 36)
        }
        .liquidGlass(panelShape)
    }
    private func sourceRow(_ title: String, icon: String, level: Float) -> some View {
        HStack {
            Image(systemName: icon).font(.system(size: 11)).frame(width: 22).foregroundStyle(ink.opacity(0.7))
            Text(title).font(.system(size: 11, weight: .medium))
            Spacer()
            Meter(level: level)
        }
    }
}
struct TranscriptRow: View {
    @EnvironmentObject var app: AppModel
    let item: Transcript
    private var mine: Bool { item.source != "remote" }
    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(mine ? "Я" : "Собеседник").font(.system(size: 10, weight: .semibold)).foregroundStyle(mine ? accent : ink.opacity(0.7))
                Text(item.time.formatted(date: .omitted, time: .standard)).font(.system(size: 9)).foregroundStyle(muted)
            }
            Text(item.text).font(.system(size: 13)).lineSpacing(4)
                .foregroundStyle(item.final ? ink.opacity(0.88) : muted)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(
                    UnevenRoundedRectangle(topLeadingRadius: mine ? 16 : 5, bottomLeadingRadius: 16, bottomTrailingRadius: 16, topTrailingRadius: mine ? 5 : 16, style: .continuous)
                        .fill(mine ? accent.opacity(item.final ? 0.22 : 0.11) : Color.white.opacity(item.final ? 0.07 : 0.04))
                )
            Button("Ответить ↗") { app.ask(item.text) }.font(.system(size: 9, weight: .medium)).buttonStyle(DialogButtonStyle(.textLink))
        }
        .padding(mine ? .leading : .trailing, 22)
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .animation(.easeOut(duration: 0.25), value: item.final)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: mine ? .bottomTrailing : .bottomLeading)).combined(with: .offset(y: 8)),
            removal: .opacity))
    }
}
struct Meter: View {
    let level: Float
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5) { index in
                Capsule().fill(level > 0.009 ? accent : Color.white.opacity(0.14))
                    .frame(width: 2, height: 3 + CGFloat(min(15, level * 180)) * [0.5, 0.8, 1, 0.7, 0.4][index])
            }
        }
        .frame(width: 20, height: 20)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

/// Shared chrome for modal sheets: dark backdrop with glass header text.
private struct SheetChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(ink)
            .tint(accent)
            .background(DialogBackdrop(compact: true))
            .preferredColorScheme(.dark)
    }
}
extension View {
    func dialogSheet() -> some View { modifier(SheetChrome()) }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(lineColor))
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("Настройки").font(.system(size: 24, weight: .semibold)).tracking(-0.6); Spacer(); DialogIconButton(symbol: "xmark", label: "Закрыть настройки", glass: true) { dismiss() } }
            Picker("Настройки", selection: $app.settingsTab) { Text("Манера ответа").tag(0); Text("Codex и звук").tag(1) }.pickerStyle(.segmented).labelsHidden()
            ScrollView {
                if app.settingsTab == 0 { styleSettings } else { connectionSettings }
            }.scrollIndicators(.automatic)
            HStack { Spacer(); Button("Готово") { dismiss() }.buttonStyle(DialogButtonStyle(.primary)).keyboardShortcut(.defaultAction) }
        }.buttonStyle(DialogButtonStyle()).padding(28).frame(width: 650, height: 690).dialogSheet().onAppear { app.refreshMicrophones() }
    }
    private var styleSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Инструкции").font(.system(size: 14, weight: .semibold))
            TextEditor(text: $app.preferences.style).font(.system(size: 13)).lineSpacing(5).scrollContentBackground(.hidden).padding(12).frame(height: 240)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DialogPalette.field))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(lineColor))
            HStack { Button("Коротко и по делу") { app.preferences.style = "Отвечай по-русски в 2–4 коротких предложениях. Начинай с сути. Разговорный язык, без вступлений и канцелярита. Ответ должно быть удобно произнести вслух." }; Button("Объяснять с примером") { app.preferences.style = "Отвечай по-русски, просто и разговорно. Сначала дай прямой ответ, затем краткое объяснение и один пример. Не больше трёх коротких абзацев. Сложные термины объясняй." } }.font(.system(size: 11, weight: .medium)).buttonStyle(DialogButtonStyle())
            SettingsCard { Toggle("Отвечать только по материалам", isOn: $app.preferences.strict).font(.system(size: 13)).toggleStyle(.switch) }
        }.padding(.top, 8)
    }
    private var connectionSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard {
                HStack(spacing: 12) {
                    Image(systemName: app.status?.connected == true ? "checkmark.circle.fill" : "person.crop.circle").foregroundStyle(app.status?.connected == true ? DialogPalette.icon : muted).font(.system(size: 25))
                    Text(app.status?.connected == true ? "Codex подключён" : "Войдите в Codex").font(.system(size: 13, weight: .medium))
                    Spacer()
                    if app.status?.connected != true { Button("Войти") { Task { await app.login() } }.buttonStyle(DialogButtonStyle(.primary)) }
                }
                Picker("Модель Codex", selection: $app.preferences.model) { ForEach(app.models) { item in Text(item.displayName).tag(item.model) } }.onChange(of: app.preferences.model) { _, _ in app.validateEffort() }
                Picker("Усилие рассуждения", selection: $app.preferences.effort) { ForEach(app.efforts, id: \.self) { Text($0 == "low" ? "Low · быстрее" : $0).tag($0) } }
            }
            SettingsCard {
                HStack { Text("Режим ответа").font(.system(size: 13)); Spacer(); DialogAnswerModePicker(automatic: $app.preferences.auto) }
                HStack {
                    Text("Клавиша ответа").font(.system(size: 13))
                    Spacer()
                    AnswerShortcutRecorder(shortcut: app.answerShortcut, onChange: app.setAnswerShortcut, onRecording: app.recordAnswerShortcut, onError: { app.shortcutError = $0 })
                        .frame(width: 200, height: 32)
                    Button("Сбросить") { app.setAnswerShortcut(.default) }.font(.system(size: 11, weight: .medium)).disabled(app.shortcutRecording)
                }
                Text("Работает и когда активно другое приложение.").font(.system(size: 11)).foregroundStyle(muted)
                if app.answerShortcut.isModifierOnly {
                    Text("Срабатывает при отдельном нажатии и отпускании. Сочетания с другими клавишами не запускают ответ.").font(.system(size: 11)).foregroundStyle(muted)
                    if app.shortcutError != nil || !ModifierAnswerMonitor.hasAccess {
                        Button("Разрешить работу клавиши в фоне") { app.enableModifierAnswerShortcut() }.font(.system(size: 12, weight: .medium)).disabled(app.shortcutRecording)
                    }
                } else if app.answerShortcut.modifiers == 0, !AnswerShortcut.functionKeys.contains(app.answerShortcut.keyCode) {
                    Text("Эта клавиша будет запускать ответ вместо ввода в других приложениях, пока «Диалог» запущен.").font(.system(size: 11)).foregroundStyle(muted)
                }
                if let error = app.shortcutError { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            }
            SettingsCard {
                Picker("Распознавание", selection: Binding(get: { app.speechEngine }, set: { engine in Task { await app.selectSpeechEngine(engine) } })) {
                    ForEach(app.speechEngines) { engine in Text(engine.name).tag(engine.id) }
                }.disabled(app.running || app.starting || app.speechSwitching)
                if let engine = app.speechEngines.first(where: { $0.id == app.speechEngine }) { Text(engine.detail).font(.system(size: 11)).foregroundStyle(muted) }
                Text("Ориентиры по коротким пробам на этом Маке. Время — без ожидания конца фразы.").font(.system(size: 10)).foregroundStyle(muted)
                HStack {
                    Circle().fill(app.speechState == "ready" ? Color.green : .orange).frame(width: 7, height: 7).shadow(color: app.speechState == "ready" ? .green : .orange, radius: 3)
                    Text(app.speechState == "ready" ? "Распознавание готово" : app.speechState == "error" ? "Распознавание недоступно" : "Подготовка распознавания…").font(.system(size: 13))
                    Spacer()
                    Button("Повторить") { Task { await app.retrySpeech() } }.font(.system(size: 11, weight: .medium)).disabled(app.running || app.starting || app.speechSwitching)
                }
                if app.speechState == "loading", !app.speechDetail.isEmpty { Text(app.speechDetail).font(.system(size: 11)).foregroundStyle(muted) }
                if let error = app.speechError { Text(error).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
                Picker("Язык разговора", selection: $app.preferences.language) { Text("Русский").tag("ru"); Text("English").tag("en") }.disabled(app.speechEngine == "gigaam")
                Picker("Пауза в конце реплики", selection: $app.preferences.pause) { Text("320 мс · быстрее").tag(320); Text("480 мс · короткие паузы").tag(480); Text("700 мс · обычно").tag(700); Text("1000 мс · спокойная речь").tag(1000) }
            }
            SettingsCard {
                Label("Системный звук", systemImage: "speaker.wave.2.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(accent)
                Toggle("Отдельно слушать мой микрофон", isOn: $app.preferences.microphone).toggleStyle(.switch).disabled(app.running || app.starting)
                HStack {
                    Picker("Микрофон", selection: Binding(get: { app.preferences.microphoneUID ?? "" }, set: { app.preferences.microphoneUID = $0.isEmpty ? nil : $0 })) {
                        Text("Системный — \(app.systemMicrophoneName)").tag("")
                        ForEach(app.microphoneDevices) { device in Text(device.name).tag(device.uid) }
                        if let uid = app.preferences.microphoneUID, !app.microphoneDevices.contains(where: { $0.uid == uid }) { Text("Выбранный микрофон отключён").tag(uid) }
                    }.accessibilityIdentifier("microphone.device")
                    DialogIconButton(symbol: "arrow.clockwise", label: "Обновить список микрофонов") { app.refreshMicrophones() }
                }.disabled(app.running || app.starting || !app.preferences.microphone).help("Устройство только для «Диалога». В звонке выбери тот же микрофон; второй не нужен.")
                Button("Открыть разрешения macOS") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }.font(.system(size: 11, weight: .medium))
            }
        }.padding(.top, 8)
    }
}

struct MaterialsView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("Материалы").font(.system(size: 24, weight: .semibold)).tracking(-0.6); Spacer(); DialogIconButton(symbol: "xmark", label: "Закрыть материалы", glass: true) { dismiss() } }
            Button { app.chooseFiles() } label: {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 26)).foregroundStyle(DialogPalette.icon)
                    Text(app.uploading ? app.uploadProgress : "Добавить файлы или папки").font(.system(size: 14, weight: .medium))
                    Text("С вложенными папками · до 20 МБ на файл").font(.system(size: 10)).foregroundStyle(muted)
                }.frame(maxWidth: .infinity).padding(25)
            }.buttonStyle(DialogButtonStyle(.card)).disabled(app.uploading)
            if app.materials.isEmpty { Text("Материалы пока не добавлены").font(.system(size: 13)).foregroundStyle(muted).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                ScrollView { LazyVStack(spacing: 0) { ForEach(app.materialGroups) { group in MaterialGroupRow(group: group, compact: false); GlassDivider() } }.padding(.horizontal, 6) }
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.04)))
            }
        }.buttonStyle(DialogButtonStyle()).padding(28).frame(width: 660, height: 540).dialogSheet()
    }
}

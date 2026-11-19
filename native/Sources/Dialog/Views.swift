import SwiftUI

private let ink = DialogPalette.ink
private let sage = DialogPalette.sage
private let muted = DialogPalette.muted
private let canvas = DialogPalette.canvas
private let lineColor = DialogPalette.line

struct ContentView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sidebarVisible = true

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                SidebarView().frame(width: 220)
                    .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            VStack(alignment: .leading, spacing: 18) {
                sessionBar
                ConversationSplitView()
                if !app.running && !app.starting { questionField }
            }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).background(canvas).disabled(app.projectSwitching)
        }
        .foregroundStyle(ink).frame(minWidth: 1050, minHeight: 720)
        .buttonStyle(DialogButtonStyle())
        .task { await app.boot() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in app.refreshAnswerShortcutAccess(); app.refreshMicrophones() }
        .onChange(of: app.running) { _, running in
            if running { setSidebarVisible(false) }
        }
        .sheet(isPresented: $app.showSettings) { SettingsView() }
        .sheet(isPresented: $app.showMaterials) { MaterialsView() }
        .sheet(isPresented: $app.showHistory) { HistoryView() }
        .sheet(isPresented: $app.showProjectEditor) { ProjectEditorView() }
        .alert("Диалог", isPresented: Binding(get: { app.message != nil }, set: { if !$0 { app.message = nil } })) { Button("Понятно", role: .cancel) { app.message = nil } } message: { Text(app.message ?? "") }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                DialogIconButton(symbol: "gearshape", label: "Настройки") { app.settingsTab = 1; app.showSettings = true }
            }
        }
    }
    private var sessionBar: some View {
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
        }.foregroundStyle(sage).padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity).background(Color(red: 0.93, green: 0.95, blue: 0.90), in: RoundedRectangle(cornerRadius: 8))
    }
    private var listeningControls: some View {
        HStack(spacing: 10) {
            DialogIconButton(symbol: "sidebar.left", label: sidebarVisible ? "Скрыть боковую панель" : "Показать боковую панель") {
                setSidebarVisible(!sidebarVisible)
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .accessibilityIdentifier("session.sidebar")
            Button { Task { await app.toggleCapture() } } label: {
                Label(app.starting ? "Подключаю…" : app.running ? "Остановить" : "Слушать", systemImage: app.running ? "stop.fill" : "waveform")
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }.buttonStyle(DialogButtonStyle(.primary, tint: app.running ? Color(red: 0.55, green: 0.31, blue: 0.23) : sage)).disabled(app.starting)
                .accessibilityIdentifier("session.listen")
            ProjectMenu()
            if !app.running && app.speechState != "ready" {
                Circle().fill(.orange).frame(width: 6, height: 6).help(app.speechState == "error" ? "Распознавание недоступно" : "Подготовка распознавания…")
            }
            if let date = app.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in Text(elapsed(context.date.timeIntervalSince(date))).monospacedDigit().font(.system(size: 10)).foregroundStyle(muted).frame(width: 37) }
            }
        }.fixedSize()
    }
    private var responseControls: some View {
        HStack(spacing: 10) {
            DialogAnswerModePicker(automatic: $app.preferences.auto)
            Button { Task { await app.answerFromConversation() } } label: {
                HStack(spacing: 7) {
                    Text(app.contextAnswerPending ? "Распознаю…" : "Ответить").lineLimit(1)
                    Text(app.answerShortcut.display).foregroundStyle(muted).lineLimit(1)
                }.font(.system(size: 11))
            }.buttonStyle(DialogButtonStyle()).disabled(!app.canAnswerFromConversation).accessibilityIdentifier("answer.context")
                .help("Ответить по текущему диалогу · \(app.answerShortcut.display). Работает и в других приложениях.")
        }.fixedSize()
    }
    private var sessionActions: some View {
        HStack(spacing: 5) {
            Divider().frame(height: 15).padding(.horizontal, 5)
            DialogIconButton(symbol: "square.and.arrow.down", label: "Сохранить расшифровку и ответы") { app.exportSession() }
            DialogIconButton(symbol: "arrow.counterclockwise", label: "Новый разговор") { Task { await app.newSession() } }
        }.fixedSize()
    }
    private func setSidebarVisible(_ visible: Bool) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) { sidebarVisible = visible }
    }
    private var questionField: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.turn.down.right").foregroundStyle(muted)
            TextField("Или введи запрос, чтобы проверить ответ…", text: $app.manualQuestion).textFieldStyle(.plain).font(.system(size: 13)).onSubmit { app.ask() }
            Text("↵").foregroundStyle(muted)
            DialogIconButton(symbol: "arrow.right", label: "Получить ответ") { app.ask() }
        }.padding(12).background(.white, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(lineColor, lineWidth: 1))
    }
    private func elapsed(_ time: TimeInterval) -> String { let seconds = max(0, Int(time)); return String(format: "%02d:%02d", seconds / 60, seconds % 60) }
}

struct SidebarView: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) { Image(systemName: "quote.bubble.fill").font(.system(size: 27)).foregroundStyle(sage); Text("диалог").font(.system(size: 29, weight: .semibold)).tracking(-1.3) }.padding(.bottom, 32)
            Button { app.showMaterials = false; app.showSettings = false } label: { Label("Разговор", systemImage: "waveform.circle").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(DialogButtonStyle(.row, selected: true)).font(.system(size: 13, weight: .medium))
            Button { app.showMaterials = true } label: { HStack { Label("Материалы", systemImage: "square.3.layers.3d"); Spacer(); Text("\(app.materialGroups.count)").font(.system(size: 10)).padding(4).background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 4)) } }.buttonStyle(DialogButtonStyle(.row)).font(.system(size: 12))
            Button { app.settingsTab = 0; app.showSettings = true } label: { Label("Манера ответа", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(DialogButtonStyle(.row)).font(.system(size: 12))
            Button { app.openHistory() } label: { Label("История", systemImage: "clock").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(DialogButtonStyle(.row)).font(.system(size: 12))
            Divider().padding(.vertical, 25)
            if !app.materials.isEmpty {
                ScrollView { LazyVStack(alignment: .leading, spacing: 4) { ForEach(app.materialGroups) { group in MaterialGroupRow(group: group, compact: true) } } }.frame(maxHeight: 220).padding(.bottom, 15)
            }
            Button { app.chooseFiles() } label: { Label(app.uploading ? app.uploadProgress : "Добавить материалы", systemImage: "plus").font(.system(size: 11)).frame(maxWidth: .infinity).padding(.vertical, 11) }.buttonStyle(DialogButtonStyle(.card)).disabled(app.uploading)
            Spacer(minLength: 25)
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(red: 0.94, green: 0.95, blue: 0.92)).disabled(app.projectSwitching)
    }
}

struct AnswerView: View {
    @EnvironmentObject var app: AppModel
    @State private var copied = false
    @State private var copyFeedback: Task<Void, Never>?
    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Подсказка для ответа", symbol: "sparkles") {
                Button("A−") { app.preferences.fontSize = max(10, app.preferences.fontSize - 2) }.buttonStyle(DialogButtonStyle(.icon)).disabled(app.preferences.fontSize <= 10).help("Уменьшить шрифт · \(Int(app.preferences.fontSize)) пт")
                Button("A+") { app.preferences.fontSize = min(40, app.preferences.fontSize + 2) }.buttonStyle(DialogButtonStyle(.icon)).disabled(app.preferences.fontSize >= 40).help("Увеличить шрифт · \(Int(app.preferences.fontSize)) пт")
                DialogIconButton(symbol: copied ? "checkmark" : "doc.on.doc", label: copied ? "Ответ скопирован" : "Скопировать весь ответ") {
                    copyFeedback?.cancel()
                    copied = app.copyAnswer()
                    if copied {
                        copyFeedback = Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            if !Task.isCancelled { copied = false }
                        }
                    }
                }.disabled(app.answer.isEmpty)
            }
            Divider()
            ScrollView {
                if app.question.isEmpty { onboarding }
                else { VStack(alignment: .leading, spacing: 22) { Text(app.question).font(.system(size: 13)).foregroundStyle(muted).textSelection(.enabled); Divider(); MarkdownResponse(text: app.answer.isEmpty && app.generating ? "Формулирую…" : app.answer, fontSize: app.preferences.fontSize, sources: app.sources); if app.generating { ProgressView().controlSize(.small) } }.padding(26).frame(maxWidth: .infinity, alignment: .leading) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if !app.question.isEmpty {
                Divider()
                HStack { Text(app.answerStatus).font(.system(size: 10)); Spacer(); if app.generating { Button("Остановить") { app.cancelAnswer() }.buttonStyle(DialogButtonStyle()).font(.system(size: 10)) } }.foregroundStyle(muted).padding(13)
            }
        }.background(.white, in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(lineColor, lineWidth: 1))
            .onChange(of: app.answer) { _, _ in copied = false }
            .onDisappear { copyFeedback?.cancel() }
    }
    private var onboarding: some View {
        VStack(spacing: 17) {
            OnboardingEmblem().padding(.top, 24).padding(.bottom, 5)
            Text("Ты слушаешь.\nОтвет уже рядом.").font(.system(size: 29, weight: .medium)).tracking(-0.8).multilineTextAlignment(.center)
            Text("Подключи звонок, и здесь появится понятный\nответ с опорой на твои материалы.").font(.system(size: 12)).foregroundStyle(muted).lineSpacing(6).multilineTextAlignment(.center)
            VStack(spacing: 0) {
                step("01", "Добавь свои материалы", "Конспекты, PDF, документы или код") { app.showMaterials = true }
                Divider()
                step("02", "Настрой манеру ответа", "Кратко, подробно, своими словами") { app.settingsTab = 0; app.showSettings = true }
                Divider()
                step("03", "Начни слушать компьютер", "Системный звук и микрофон") { Task { await app.toggleCapture() } }
            }.padding(.top, 15).frame(maxWidth: 340)
        }.padding(25).frame(maxWidth: .infinity)
    }
    private func step(_ number: String, _ title: String, _ subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(number).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
                VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 12, weight: .medium)); Text(subtitle).font(.system(size: 10)).foregroundStyle(muted) }
                Spacer()
                Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(muted)
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(DialogButtonStyle(.row))
        .accessibilityIdentifier("onboarding.\(number)")
    }
}

private struct OnboardingEmblem: View {
    var body: some View {
        ZStack {
            Ellipse().stroke(lineColor, lineWidth: 1).frame(width: 68, height: 54).rotationEffect(.degrees(-25))
            RoundedRectangle(cornerRadius: 15).fill(canvas).overlay(RoundedRectangle(cornerRadius: 15).stroke(lineColor)).frame(width: 45, height: 45).rotationEffect(.degrees(-8))
            Image(systemName: "sparkles").font(.system(size: 25, weight: .light)).foregroundStyle(sage.opacity(0.65))
            Circle().fill(Color(red: 0.76, green: 0.84, blue: 0.63)).frame(width: 7, height: 7).offset(x: -24, y: -25)
            Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium)).foregroundStyle(sage.opacity(0.65)).frame(width: 21, height: 21).background(.white, in: Circle()).overlay(Circle().stroke(lineColor)).offset(x: 25, y: 23)
        }.frame(width: 76, height: 68).accessibilityHidden(true)
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
        HStack(spacing: 8) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 8)
            actions
        }
        .foregroundStyle(sage)
        .padding(.horizontal, 18)
        .frame(height: 56)
    }
}

struct TranscriptView: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Диалог", symbol: "text.bubble") {
                if app.running { Circle().fill(sage).frame(width: 6, height: 6).accessibilityLabel("Запись") }
            }
            Divider()
            VStack(spacing: 12) {
                sourceRow("Собеседник", icon: "speaker.wave.2", level: app.remoteLevel)
                HStack { Image(systemName: "mic").frame(width: 22).foregroundStyle(muted); Text("Я").font(.system(size: 11)); Spacer(); Toggle("Микрофон", isOn: $app.preferences.microphone).labelsHidden().toggleStyle(.switch).controlSize(.mini).disabled(app.running || app.starting); Meter(level: app.micLevel) }.help(app.activeMicrophoneName ?? "Микрофон для своего голоса выбирается в настройках")
                if let issue = app.microphoneIssue { Label(issue, systemImage: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding(16)
            Divider()
            if app.transcript.isEmpty {
                VStack(spacing: 14) {
                    Spacer()
                    HStack(spacing: 4) {
                        ForEach(0..<9) { index in Capsule().fill(Color(red: 0.86, green: 0.90, blue: 0.81)).frame(width: 3, height: [10.0, 18, 25, 18, 32, 25, 10, 18, 25][index]) }
                    }.frame(height: 34).accessibilityHidden(true)
                    Text("Здесь будет ваш диалог").font(.system(size: 12, weight: .medium)).foregroundStyle(muted).padding(.top, 8)
                    Text("Два источника звука.\nКаждая реплика на своём месте.").font(.system(size: 11)).foregroundStyle(muted.opacity(0.75)).multilineTextAlignment(.center).lineSpacing(6)
                    Spacer()
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in ScrollView { LazyVStack(alignment: .leading, spacing: 22) { ForEach(app.transcript) { item in TranscriptRow(item: item).id(item.id) } }.padding(18) }.onChange(of: app.transcript.last?.text) { _, _ in if let id = app.transcript.last?.id { proxy.scrollTo(id, anchor: .bottom) } } }
            }
            Divider()
            Label("В наушниках распознавание точнее", systemImage: "headphones").font(.system(size: 9)).foregroundStyle(muted).padding(13)
        }.background(.white, in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(lineColor, lineWidth: 1))
    }
    private func sourceRow(_ title: String, icon: String, level: Float) -> some View { HStack { Image(systemName: icon).frame(width: 22).foregroundStyle(muted); Text(title).font(.system(size: 11)); Spacer(); Meter(level: level) } }
}
struct TranscriptRow: View {
    @EnvironmentObject var app: AppModel
    let item: Transcript
    var body: some View { VStack(alignment: .leading, spacing: 8) { HStack { Text(item.source == "remote" ? "Собеседник" : "Я").font(.system(size: 10, weight: .semibold)).foregroundStyle(item.source == "remote" ? sage : Color.brown.opacity(0.7)); Text(item.time.formatted(date: .omitted, time: .standard)).font(.system(size: 9)).foregroundStyle(muted) }; Text(item.text).font(.system(size: 13)).lineSpacing(5).foregroundStyle(item.final ? ink.opacity(0.8) : muted).textSelection(.enabled); Button("Ответить ↗") { app.ask(item.text) }.font(.system(size: 9)).buttonStyle(DialogButtonStyle(.textLink)).frame(maxWidth: .infinity, alignment: .trailing) } }
}
struct Meter: View {
    let level: Float
    var body: some View { HStack(spacing: 2) { ForEach(0..<5) { index in Capsule().fill(level > 0.009 ? sage.opacity(0.7) : lineColor).frame(width: 2, height: 3 + CGFloat(min(15, level * 180)) * [0.5, 0.8, 1, 0.7, 0.4][index]) } }.frame(width: 20, height: 20) }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("Настройки").font(.system(size: 24, weight: .medium)); Spacer(); DialogIconButton(symbol: "xmark", label: "Закрыть настройки") { dismiss() } }
            Picker("Настройки", selection: $app.settingsTab) { Text("Манера ответа").tag(0); Text("Codex и звук").tag(1) }.pickerStyle(.segmented)
            ScrollView {
                if app.settingsTab == 0 { styleSettings } else { connectionSettings }
            }
            Divider()
            HStack { Spacer(); Button("Готово") { dismiss() }.buttonStyle(DialogButtonStyle(.primary)).keyboardShortcut(.defaultAction) }
        }.buttonStyle(DialogButtonStyle()).padding(28).frame(width: 650, height: 670).background(canvas).onAppear { app.refreshMicrophones() }
    }
    private var styleSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Инструкции").font(.system(size: 14, weight: .medium))
            TextEditor(text: $app.preferences.style).font(.system(size: 13)).lineSpacing(5).padding(10).frame(height: 240).background(.white).clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(lineColor))
            HStack { Button("Коротко и по делу") { app.preferences.style = "Отвечай по-русски в 2–4 коротких предложениях. Начинай с сути. Разговорный язык, без вступлений и канцелярита. Ответ должно быть удобно произнести вслух." }; Button("Объяснять с примером") { app.preferences.style = "Отвечай по-русски, просто и разговорно. Сначала дай прямой ответ, затем краткое объяснение и один пример. Не больше трёх коротких абзацев. Сложные термины объясняй." } }.font(.system(size: 11)).buttonStyle(DialogButtonStyle())
            Toggle("Отвечать только по материалам", isOn: $app.preferences.strict).font(.system(size: 13))
        }.padding(.top, 8)
    }
    private var connectionSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Режим ответа").font(.system(size: 13)); Spacer(); DialogAnswerModePicker(automatic: $app.preferences.auto) }
            HStack {
                Text("Клавиша ответа").font(.system(size: 13))
                Spacer()
                AnswerShortcutRecorder(shortcut: app.answerShortcut, onChange: app.setAnswerShortcut, onRecording: app.recordAnswerShortcut, onError: { app.shortcutError = $0 })
                    .frame(width: 200, height: 32)
                Button("Сбросить") { app.setAnswerShortcut(.default) }.font(.system(size: 11)).disabled(app.shortcutRecording)
            }
            Text("Работает и когда активно другое приложение.").font(.system(size: 11)).foregroundStyle(muted)
            if app.answerShortcut.isModifierOnly {
                Text("Срабатывает при отдельном нажатии и отпускании. Сочетания с другими клавишами не запускают ответ.").font(.system(size: 11)).foregroundStyle(muted)
                if app.shortcutError != nil || !ModifierAnswerMonitor.hasAccess {
                    Button("Разрешить работу клавиши в фоне") { app.enableModifierAnswerShortcut() }.font(.system(size: 12)).disabled(app.shortcutRecording)
                }
            } else if app.answerShortcut.modifiers == 0, !AnswerShortcut.functionKeys.contains(app.answerShortcut.keyCode) {
                Text("Эта клавиша будет запускать ответ вместо ввода в других приложениях, пока «Диалог» запущен.").font(.system(size: 11)).foregroundStyle(muted)
            }
            if let error = app.shortcutError { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            Divider()
            HStack(spacing: 12) { Image(systemName: app.status?.connected == true ? "checkmark.circle.fill" : "person.crop.circle").foregroundStyle(sage).font(.system(size: 25)); Text(app.status?.connected == true ? "Codex подключён" : "Войдите в Codex").font(.system(size: 13, weight: .medium)); Spacer(); if app.status?.connected != true { Button("Войти") { Task { await app.login() } } } }.padding(15).background(sage.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            Picker("Модель Codex", selection: $app.preferences.model) { ForEach(app.models) { item in Text(item.displayName).tag(item.model) } }.onChange(of: app.preferences.model) { _, _ in app.validateEffort() }
            Picker("Усилие рассуждения", selection: $app.preferences.effort) { ForEach(app.efforts, id: \.self) { Text($0 == "low" ? "Low · быстрее" : $0).tag($0) } }
            Divider()
            Picker("Распознавание", selection: Binding(get: { app.speechEngine }, set: { engine in Task { await app.selectSpeechEngine(engine) } })) {
                ForEach(app.speechEngines) { engine in Text(engine.name).tag(engine.id) }
            }.disabled(app.running || app.starting || app.speechSwitching)
            if let engine = app.speechEngines.first(where: { $0.id == app.speechEngine }) { Text(engine.detail).font(.system(size: 11)).foregroundStyle(muted) }
            Text("Ориентиры по коротким пробам на этом Маке. Время — без ожидания конца фразы.").font(.system(size: 10)).foregroundStyle(muted)
            HStack { Circle().fill(app.speechState == "ready" ? sage : .orange).frame(width: 7, height: 7); Text(app.speechState == "ready" ? "Распознавание готово" : app.speechState == "error" ? "Распознавание недоступно" : "Подготовка распознавания…").font(.system(size: 13)); Spacer(); Button("Повторить") { Task { await app.retrySpeech() } }.disabled(app.running || app.starting || app.speechSwitching) }
            if app.speechState == "loading", !app.speechDetail.isEmpty { Text(app.speechDetail).font(.system(size: 11)).foregroundStyle(muted) }
            if let error = app.speechError { Text(error).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
            Label("Системный звук", systemImage: "speaker.wave.2").font(.system(size: 12)).foregroundStyle(sage)
            Toggle("Отдельно слушать мой микрофон", isOn: $app.preferences.microphone).disabled(app.running || app.starting)
            HStack {
                Picker("Микрофон", selection: Binding(get: { app.preferences.microphoneUID ?? "" }, set: { app.preferences.microphoneUID = $0.isEmpty ? nil : $0 })) {
                    Text("Системный — \(app.systemMicrophoneName)").tag("")
                    ForEach(app.microphoneDevices) { device in Text(device.name).tag(device.uid) }
                    if let uid = app.preferences.microphoneUID, !app.microphoneDevices.contains(where: { $0.uid == uid }) { Text("Выбранный микрофон отключён").tag(uid) }
                }.accessibilityIdentifier("microphone.device")
                DialogIconButton(symbol: "arrow.clockwise", label: "Обновить список микрофонов") { app.refreshMicrophones() }
            }.disabled(app.running || app.starting || !app.preferences.microphone).help("Устройство только для «Диалога». В звонке выбери тот же микрофон; второй не нужен.")
            Picker("Язык разговора", selection: $app.preferences.language) { Text("Русский").tag("ru"); Text("English").tag("en") }.disabled(app.speechEngine == "gigaam")
            Picker("Пауза в конце реплики", selection: $app.preferences.pause) { Text("320 мс · быстрее").tag(320); Text("480 мс · короткие паузы").tag(480); Text("700 мс · обычно").tag(700); Text("1000 мс · спокойная речь").tag(1000) }
            Button("Открыть разрешения macOS") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }.font(.system(size: 11))
        }.padding(.top, 8)
    }
}

struct MaterialsView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("Материалы").font(.system(size: 23, weight: .medium)); Spacer(); DialogIconButton(symbol: "xmark", label: "Закрыть материалы") { dismiss() } }
            Button { app.chooseFiles() } label: { VStack(spacing: 12) { Image(systemName: "folder.badge.plus").font(.system(size: 26)); Text(app.uploading ? app.uploadProgress : "Добавить файлы или папки").font(.system(size: 14, weight: .medium)); Text("С вложенными папками · до 20 МБ на файл").font(.system(size: 10)) }.foregroundStyle(sage).frame(maxWidth: .infinity).padding(25) }.buttonStyle(DialogButtonStyle(.card)).disabled(app.uploading)
            if app.materials.isEmpty { Text("Материалы пока не добавлены").font(.system(size: 13)).foregroundStyle(muted).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { ScrollView { LazyVStack(spacing: 0) { ForEach(app.materialGroups) { group in MaterialGroupRow(group: group, compact: false); Divider() } } } }
        }.buttonStyle(DialogButtonStyle()).padding(28).frame(width: 660, height: 540).background(canvas)
    }
}

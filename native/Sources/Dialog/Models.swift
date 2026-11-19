import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ModelOption: Decodable, Identifiable {
    var id: String { model }
    let model: String
    let displayName: String
    let supportedReasoningEfforts: [Effort]
    let defaultReasoningEffort: String
    struct Effort: Decodable { let reasoningEffort: String }
}
struct ConnectionStatus: Decodable {
    let connected: Bool
    let models: [ModelOption]
    let speech: String
    let speechError: String?
    let defaultStyle: String?
    let error: String?
    let speechEngine: String?
    let speechEngines: [SpeechEngineOption]?
    let speechDetail: String?
}
struct SpeechEngineOption: Decodable, Identifiable {
    let id: String; let name: String; let detail: String; let languages: [String]
}
struct Material: Decodable, Identifiable { let id: String; let name: String; let characters: Int; let chunks: Int }
struct Source: Identifiable, Decodable {
    var id: Int { ref }; let ref: Int; let name: String; let line: Int; let text: String
    init?(_ data: [String: Any]) { guard let ref = data["ref"] as? Int, let name = data["name"] as? String else { return nil }; self.ref = ref; self.name = name; self.line = data["line"] as? Int ?? 1; self.text = data["text"] as? String ?? "" }
}
struct Transcript: Identifiable, Decodable { let id: String; let source: String; var text: String; var final: Bool; let time: Date; var seq: Int? = nil }
struct AnswerRecord { let question: String; var text: String; let sources: [Source] }
struct SavedExchange: Identifiable, Decodable { let id: String; let question: String; let text: String; let status: String; let time: Date; let seq: Int; let answerSeq: Int?; let sources: [Source] }
struct ConversationSnapshot: Decodable { let id: String; let title: String; let transcript: [Transcript]; let exchanges: [SavedExchange] }
struct ConversationSummary: Identifiable, Decodable { let id: String; let title: String; let updatedAt: Date; let transcriptCount: Int; let answerCount: Int }
struct Preferences: Codable {
    var model = ""; var effort = "low"; var style = ""; var auto = true; var strict = false
    var microphone = true; var language = "ru"; var pause = 700; var fontSize: Double = 26
    var appID: Int32 = 0
    var sessionID: String? = nil
    var speechPipelineVersion: Int? = nil
    var answerShortcut: AnswerShortcut? = nil
    var projectID: String? = nil
    var microphoneUID: String? = nil
}

@MainActor final class AppModel: ObservableObject {
    @Published var status: ConnectionStatus?
    @Published var materials: [Material] = [] {
        didSet { materialGroups = MaterialGroup.collect(materials) }
    }
    @Published private(set) var materialGroups: [MaterialGroup] = []
    @Published var transcript: [Transcript] = []
    @Published var answer = ""
    @Published var question = ""
    @Published var manualQuestion = ""
    @Published var sources: [Source] = []
    @Published var generating = false
    @Published var running = false
    @Published var starting = false
    @Published var online = false
    @Published var message: String?
    @Published var answerStatus = "Ожидаем вопрос"
    @Published var speechState = "loading"
    @Published var speechError: String?
    @Published var speechEngine = "parakeet"
    @Published var speechDetail = ""
    @Published var speechSwitching = false
    @Published var contextAnswerPending = false
    @Published var shortcutError: String?
    @Published var shortcutRecording = false
    @Published var remoteLevel: Float = 0
    @Published var micLevel: Float = 0
    @Published var microphoneDevices: [MicrophoneDevice] = []
    @Published var systemMicrophoneName = "не выбран"
    @Published var activeMicrophoneName: String?
    @Published var microphoneIssue: String?
    @Published var startedAt: Date?
    @Published var uploading = false
    @Published var showSettings = false
    @Published var showMaterials = false
    @Published var showHistory = false
    @Published var sessions: [ConversationSummary] = []
    @Published var historyPreview: ConversationSnapshot?
    @Published var uploadProgress = ""
    @Published var settingsTab = 0
    @Published var audioApps: [AudioApp] = []
    @Published var projects: [ProjectOption] = []
    @Published var currentProject: ProjectOption?
    @Published var projectSwitching = false
    @Published var projectSaving = false
    @Published var showProjectEditor = false
    @Published var projectEditorRename = false
    @Published var projectNameDraft = ""
    @Published var projectEditorError: String?
    @Published var preferences: Preferences {
        didSet { if let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: "dialog.preferences") }; sendSettings() }
    }
    private var websocket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var poller: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var capture: AudioCapture?
    private var records: [AnswerRecord] = []
    private var booted = false
    private var stopping = false
    private let globalAnswerShortcut = GlobalAnswerShortcut()
    private var pendingSpeechFinals: Set<String> = []
    private var applyingProject = false
    private var settingsRevision = 0
    private let settingsClientID = UUID().uuidString
    private var pendingProjectID: String?
    private var projectSwitchTimeout: Task<Void, Never>?
    var projectBusy: Bool { projectSwitching || projectSaving }
    var currentProjectID: String { currentProject?.id ?? preferences.projectID ?? "general" }
    var answerShortcut: AnswerShortcut { preferences.answerShortcut ?? .default }
    var canAnswerFromConversation: Bool { online && currentProject != nil && !projectBusy && status?.connected == true && !contextAnswerPending && (!transcript.isEmpty || !answer.isEmpty || running) }
    var models: [ModelOption] { status?.models.filter { $0.model.hasPrefix("gpt-") } ?? [] }
    var efforts: [String] { models.first(where: { $0.model == preferences.model })?.supportedReasoningEfforts.map(\.reasoningEffort) ?? ["low"] }
    var speechEngines: [SpeechEngineOption] { status?.speechEngines ?? [] }
    init() {
        var saved = UserDefaults.standard.data(forKey: "dialog.preferences").flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
        if saved.speechPipelineVersion == nil { saved.pause = max(700, saved.pause); saved.speechPipelineVersion = 1 }
        preferences = saved
    }
    func boot() async {
        guard !booted else { return }; booted = true
        refreshMicrophones()
        globalAnswerShortcut.onPress = { [weak self] in Task { @MainActor in await self?.answerFromConversation() } }
        shortcutError = globalAnswerShortcut.register(answerShortcut)
        do {
            try await BackendProcess.shared.ensureRunning()
            await refreshStatus()
            if preferences.projectID == nil {
                let body = try JSONSerialization.data(withJSONObject: ["style": preferences.style, "strict": preferences.strict, "model": preferences.model, "effort": preferences.effort, "sessionID": preferences.sessionID ?? ""])
                _ = try await BackendProcess.shared.request("/api/projects/general/initialize", method: "POST", body: body)
            }
            await loadProjects(); connect()
            poller = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(6)); guard !Task.isCancelled else { break }
                    if self?.speechState != "ready" { await self?.refreshStatus() }
                }
            }
        } catch { message = error.localizedDescription; booted = false }
    }
    func refreshStatus() async {
        do {
            let data = try await BackendProcess.shared.request("/api/status")
            let value = try JSONDecoder().decode(ConnectionStatus.self, from: data)
            status = value; speechState = value.speech; speechError = value.speechError
            speechEngine = value.speechEngine ?? speechEngine; speechDetail = value.speechDetail ?? ""
            if speechEngine == "gigaam", preferences.language != "ru" { preferences.language = "ru" }
            if currentProject == nil, preferences.style.isEmpty { preferences.style = value.defaultStyle ?? "" }
            if !models.contains(where: { $0.model == preferences.model }) { preferences.model = models.first(where: { $0.model.contains("luna") || $0.model.contains("mini") })?.model ?? models.first?.model ?? "" }
            validateEffort()
        } catch { message = error.localizedDescription }
    }
    func validateEffort() { if !efforts.contains(preferences.effort) { preferences.effort = ["none", "minimal", "low"].first(where: { efforts.contains($0) }) ?? efforts.first ?? "low" } }
    func connect() {
        receiver?.cancel(); websocket?.cancel(with: .goingAway, reason: nil)
        let endpoint = BackendProcess.shared
        var req = URLRequest(url: URL(string: "ws://127.0.0.1:\(endpoint.port)/live")!)
        req.setValue(endpoint.base.absoluteString, forHTTPHeaderField: "Origin")
        let socket = URLSession.shared.webSocketTask(with: req); websocket = socket; socket.resume()
        socket.maximumMessageSize = 64 * 1024 * 1024
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let event = try await socket.receive()
                    let data: Data
                    switch event { case .string(let text): data = Data(text.utf8); case .data(let bytes): data = bytes; @unknown default: continue }
                    if let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] { self?.handle(value) }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.online = false; self?.generating = false
                self?.pendingSpeechFinals.removeAll()
                self?.projectSwitchTimeout?.cancel(); self?.projectSwitching = false; self?.pendingProjectID = nil
                if self?.running == true { await self?.stopCapture() }
                self?.reconnect = Task { try? await Task.sleep(for: .seconds(2)); guard !Task.isCancelled else { return }; self?.connect() }
            }
        }
    }
    func send(_ object: [String: Any]) {
        var object = object
        if object["type"] as? String != "project.open", let project = currentProject, object["projectId"] == nil { object["projectId"] = project.id }
        guard let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8), let socket = websocket else { return }
        socket.send(.string(text)) { _ in }
    }
    func sendSettings() {
        guard currentProject != nil, !applyingProject, !projectSwitching else { return }
        settingsRevision += 1
        send(["type": "settings", "model": preferences.model, "effort": preferences.effort, "style": preferences.style, "auto": preferences.auto, "strict": preferences.strict, "clientId": settingsClientID, "revision": settingsRevision])
    }
    func handle(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        if let projectID = event["projectId"] as? String, projectID != currentProjectID { return }
        if projectSwitching && (type.hasPrefix("answer.") || type.hasPrefix("agent.")) { return }
        switch type {
        case "connected":
            online = true; requestProject(preferences.projectID ?? "general")
        case "project.snapshot":
            do {
                let snapshot = try historyDecoder().decode(ProjectSnapshot.self, from: JSONSerialization.data(withJSONObject: event))
                guard pendingProjectID == nil || pendingProjectID == snapshot.project.id else { return }
                applyProject(snapshot)
            } catch { projectSwitching = false; message = error.localizedDescription }
        case "project.error":
            projectSwitchTimeout?.cancel(); pendingProjectID = nil; projectSwitching = false; message = event["message"] as? String
        case "session.snapshot":
            if let object = event["session"], let data = try? JSONSerialization.data(withJSONObject: object), let snapshot = try? historyDecoder().decode(ConversationSnapshot.self, from: data) { applySnapshot(snapshot) }
        case "answer.sources": sources = (event["sources"] as? [[String: Any]] ?? []).compactMap(Source.init)
        case "agent.tool":
            let tool = event["tool"] as? String ?? ""
            answerStatus = tool == "read_material" ? "Читаю материал…" : tool == "conversation_history" ? "Смотрю историю…" : "Ищу в материалах…"
        case "agent.compacting": answerStatus = "Обновляю контекст…"
        case "error": message = event["message"] as? String
        case "transcript":
            guard let id = event["id"] as? String, let text = event["text"] as? String else { return }
            let final = event["final"] as? Bool ?? false
            if final { pendingSpeechFinals.remove(id) }
            if text.isEmpty { if final { transcript.removeAll { $0.id == id && !$0.final } }; return }
            if let i = transcript.firstIndex(where: { $0.id == id }) { if !transcript[i].final || final { transcript[i].text = text; transcript[i].final = final } }
            else { transcript.append(Transcript(id: id, source: event["source"] as? String ?? "remote", text: text, final: final, time: Date(timeIntervalSince1970: (event["time"] as? Double ?? Date().timeIntervalSince1970 * 1000) / 1000))); transcript.sort { $0.time < $1.time } }
        case "answer.start":
            question = event["question"] as? String ?? ""; answer = ""; generating = true; answerStatus = "Codex формулирует ответ…"
            sources = (event["sources"] as? [[String: Any]] ?? []).compactMap(Source.init)
            records.append(AnswerRecord(question: question, text: "", sources: sources))
        case "answer.delta":
            answer += event["delta"] as? String ?? ""
            if let first = event["firstToken"] as? Double { answerStatus = String(format: "Первый текст за %.1f с", first / 1000) }
        case "answer.done":
            generating = false; answer = event["text"] as? String ?? answer
            if let first = event["firstToken"] as? Double { answerStatus = String(format: "Готово · первый текст %.1f с", first / 1000) }
            if !records.isEmpty { records[records.count - 1].text = answer }
        case "answer.error": generating = false; answerStatus = "Ошибка ответа"; message = event["message"] as? String
        case "answer.cancelled": generating = false; answerStatus = "Ответ остановлен"; answer = event["text"] as? String ?? answer
        case "connection.status": Task { await refreshStatus() }
        case "speech.ready": speechState = "ready"; speechError = nil; speechDetail = ""; speechEngine = event["engine"] as? String ?? speechEngine
        case "speech.loading": speechState = "loading"; speechError = nil; speechDetail = event["detail"] as? String ?? ""; speechEngine = event["engine"] as? String ?? speechEngine
        case "speech.warning": speechError = event["message"] as? String
        case "speech.error":
            speechState = "error"; speechError = event["message"] as? String
            pendingSpeechFinals.removeAll()
            transcript.removeAll { !$0.final }
            if running { Task { await stopCapture() } }
        default: break
        }
    }
    func ask(_ text: String? = nil) {
        guard !projectBusy, currentProject != nil else { return }
        let value = (text ?? manualQuestion).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard online, status?.connected == true else { settingsTab = 1; showSettings = true; message = "Сначала подключите Codex через ChatGPT"; return }
        sendSettings(); send(["type": "question", "text": value]); manualQuestion = ""
    }
    func setAnswerShortcut(_ shortcut: AnswerShortcut) {
        if let error = globalAnswerShortcut.register(shortcut) {
            if shortcut.isModifierOnly, !ModifierAnswerMonitor.hasAccess { preferences.answerShortcut = shortcut }
            shortcutError = error; return
        }
        shortcutError = nil; preferences.answerShortcut = shortcut
    }
    func refreshAnswerShortcutAccess() {
        guard answerShortcut.isModifierOnly, !shortcutRecording else { return }
        shortcutError = globalAnswerShortcut.register(answerShortcut)
    }
    func enableModifierAnswerShortcut() {
        guard !shortcutRecording else { return }
        if !ModifierAnswerMonitor.hasAccess { _ = CGRequestListenEventAccess() }
        refreshAnswerShortcutAccess()
        if !ModifierAnswerMonitor.hasAccess { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!) }
    }
    func recordAnswerShortcut(_ recording: Bool) {
        shortcutRecording = recording
        if recording { shortcutError = nil; globalAnswerShortcut.suspend() }
        else if let error = globalAnswerShortcut.register(answerShortcut) { shortcutError = error }
    }
    func answerFromConversation() async {
        guard !projectBusy, currentProject != nil else { return }
        guard !contextAnswerPending else { return }
        guard online, status?.connected == true else { answerStatus = "Нет подключения к Codex"; return }
        guard !transcript.isEmpty || !answer.isEmpty || running else { answerStatus = "Сначала начни разговор"; return }
        contextAnswerPending = true
        let sessionID = preferences.sessionID
        defer { contextAnswerPending = false; send(["type": "context.cancel"]) }
        sendSettings(); send(["type": "context.prepare"])
        answerStatus = "Завершаю распознавание…"
        let flushed = capture?.finishUtterances() ?? []
        pendingSpeechFinals.formUnion(flushed)
        // Audio callbacks enqueue on the main actor before sending their final PCM.
        await Task.yield()
        let deadline = Date().addingTimeInterval(4)
        while !pendingSpeechFinals.isEmpty, online, speechState != "error", preferences.sessionID == sessionID, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
        guard online, preferences.sessionID == sessionID else { return }
        let live = transcript.filter { !$0.final }.map { ["id": $0.id, "source": $0.source, "text": $0.text, "time": $0.time.timeIntervalSince1970 * 1000] as [String: Any] }
        send(["type": "question.context", "liveTranscript": live])
        answerStatus = "Codex формулирует ответ…"
    }
    func toggleCapture() async {
        if running { await stopCapture(); return }
        guard !starting, !projectBusy, currentProject != nil else { return }
        guard online, status?.connected == true, speechState == "ready" else { settingsTab = 1; showSettings = true; return }
        starting = true
        let audio = AudioCapture()
        let audioProjectID = currentProjectID, audioSessionID = preferences.sessionID ?? "", audioLanguage = preferences.language
        audio.onAudio = { [weak self] source, id, pcm, final, time in
            Task { @MainActor in
                guard let self else { return }
                guard self.currentProjectID == audioProjectID, self.preferences.sessionID == audioSessionID else { return }
                if final { self.pendingSpeechFinals.insert(id) }
                self.send(["type": "audio", "source": source, "id": id, "audio": pcm.base64EncodedString(), "final": final, "time": time * 1000, "language": audioLanguage, "projectId": audioProjectID, "sessionId": audioSessionID])
            }
        }
        audio.onLevel = { [weak self] source, level in Task { @MainActor in if source == "remote" { self?.remoteLevel = level } else { self?.micLevel = level } } }
        audio.onStopped = { [weak self] text in Task { @MainActor in self?.message = text; await self?.stopCapture() } }
        audio.onMicrophoneState = { [weak self, weak audio] name, issue in
            Task { @MainActor in
                guard let self, let audio, self.capture === audio else { return }
                self.activeMicrophoneName = name; self.microphoneIssue = issue
                self.refreshMicrophones()
            }
        }
        capture = audio
        microphoneIssue = nil; activeMicrophoneName = nil
        do { try await audio.start(microphone: preferences.microphone, microphoneUID: preferences.microphoneUID, application: 0, pause: preferences.pause); running = true; startedAt = Date() }
        catch { await audio.stop(); capture = nil; message = error.localizedDescription }
        starting = false
    }
    func stopCapture() async { guard !stopping else { return }; stopping = true; running = false; let audio = capture; capture = nil; await audio?.stop(); remoteLevel = 0; micLevel = 0; activeMicrophoneName = nil; microphoneIssue = nil; stopping = false }
    func refreshMicrophones() {
        microphoneDevices = MicrophoneDevices.available()
        systemMicrophoneName = microphoneDevices.first(where: { $0.id == MicrophoneDevices.defaultID() })?.name ?? "не выбран"
    }
    func refreshAudioApps() async { do { audioApps = try await AudioCapture.applications() } catch { message = error.localizedDescription } }
    func selectSpeechEngine(_ engine: String) async {
        guard !running, !starting, !speechSwitching, engine != speechEngine else { return }
        speechSwitching = true; speechEngine = engine; speechState = "loading"; speechError = nil
        if engine == "gigaam" { preferences.language = "ru" }
        defer { speechSwitching = false }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["engine": engine])
            _ = try await BackendProcess.shared.request("/api/speech/engine", method: "POST", body: body)
            await refreshStatus()
        } catch { message = error.localizedDescription; await refreshStatus() }
    }
    func cancelAnswer() { send(["type": "cancel"]); generating = false; answerStatus = "Ответ остановлен" }
    func newSession() async { guard !projectBusy else { return }; await stopCapture(); pendingSpeechFinals.removeAll(); send(["type": "clear"]); transcript = []; records = []; answer = ""; question = ""; sources = []; generating = false; startedAt = nil; answerStatus = "Ожидаем вопрос" }
    private func historyDecoder() -> JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970; return decoder }
    private func applySnapshot(_ snapshot: ConversationSnapshot) {
        preferences.sessionID = snapshot.id; transcript = snapshot.transcript
        records = snapshot.exchanges.map { AnswerRecord(question: $0.question, text: $0.text, sources: $0.sources) }
        let last = snapshot.exchanges.last; question = last?.question ?? ""; answer = last?.text ?? ""; sources = last?.sources ?? []
        generating = last?.status == "inProgress"; answerStatus = generating ? "Codex формулирует ответ…" : last == nil ? "Ожидаем вопрос" : "Готово"
        Task { await loadSessions() }
    }
    func loadSessions() async {
        let projectID = currentProjectID
        do { let value = try historyDecoder().decode([ConversationSummary].self, from: await BackendProcess.shared.request(projectPath("sessions", id: projectID))); if currentProjectID == projectID { sessions = value } }
        catch { message = error.localizedDescription }
    }
    func previewSession(_ id: String) async {
        let projectID = currentProjectID
        do { let value = try historyDecoder().decode(ConversationSnapshot.self, from: await BackendProcess.shared.request(projectPath("sessions/" + id, id: projectID))); if currentProjectID == projectID { historyPreview = value } }
        catch { message = error.localizedDescription }
    }
    func openHistory() { showHistory = true; Task { await loadSessions(); if let id = preferences.sessionID { await previewSession(id) } } }
    func resumeSession(_ id: String) async { guard !projectBusy else { return }; await stopCapture(); send(["type": "session.open", "id": id]); showHistory = false }
    func loadMaterials() async {
        let projectID = currentProjectID
        do { let value = try JSONDecoder().decode([Material].self, from: await BackendProcess.shared.request(projectPath("materials", id: projectID))); if currentProjectID == projectID { materials = value } }
        catch { message = error.localizedDescription }
    }
    private func projectPath(_ suffix: String, id: String? = nil) -> String { "/api/projects/\(id ?? currentProjectID)/\(suffix)" }
    func loadProjects() async { do { projects = try JSONDecoder().decode([ProjectOption].self, from: await BackendProcess.shared.request("/api/projects")) } catch { message = error.localizedDescription } }
    private func persistProjectSettings() async throws {
        guard let project = currentProject else { return }
        settingsRevision += 1
        let body = try JSONSerialization.data(withJSONObject: ["style": preferences.style, "strict": preferences.strict, "model": preferences.model, "effort": preferences.effort, "clientId": settingsClientID, "revision": settingsRevision])
        _ = try await BackendProcess.shared.request(projectPath("settings", id: project.id), method: "PATCH", body: body)
    }
    private func requestProject(_ preferredID: String) {
        let id = projects.isEmpty || projects.contains(where: { $0.id == preferredID }) ? preferredID : "general"
        projectSwitching = true; pendingProjectID = id
        send(["type": "project.open", "id": id])
        projectSwitchTimeout?.cancel()
        projectSwitchTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20)); guard !Task.isCancelled, let self, self.pendingProjectID == id else { return }
            self.projectSwitching = false; self.pendingProjectID = nil; self.message = "Не удалось переключить проект. Подключаюсь заново."; self.connect()
        }
    }
    private func applyProject(_ snapshot: ProjectSnapshot) {
        projectSwitchTimeout?.cancel(); pendingProjectID = nil; applyingProject = true
        projects = snapshot.projects; currentProject = snapshot.project.option
        var next = preferences
        next.projectID = snapshot.project.id; next.style = snapshot.project.settings.style; next.strict = snapshot.project.settings.strict
        next.model = snapshot.project.settings.model; next.effort = snapshot.project.settings.effort
        if !models.contains(where: { $0.model == next.model }) { next.model = models.first(where: { $0.model.contains("luna") || $0.model.contains("mini") })?.model ?? models.first?.model ?? "" }
        preferences = next; validateEffort()
        materials = snapshot.materials; sessions = []; historyPreview = nil; manualQuestion = ""; startedAt = nil
        pendingSpeechFinals.removeAll(); applySnapshot(snapshot.session)
        applyingProject = false; projectSwitching = false; sendSettings()
    }
    func switchProject(_ id: String) async {
        guard !projectBusy, id != currentProject?.id else { return }
        projectSwitching = true; cancelAnswer(); showHistory = false; showMaterials = false; showSettings = false
        await stopCapture(); await Task.yield()
        let deadline = Date().addingTimeInterval(4)
        while !pendingSpeechFinals.isEmpty, online, speechState != "error", Date() < deadline { try? await Task.sleep(for: .milliseconds(40)) }
        do { try await persistProjectSettings(); requestProject(id) }
        catch { projectSwitching = false; message = error.localizedDescription }
    }
    func beginProjectEditor(rename: Bool) {
        guard !projectBusy, !uploading, let project = currentProject, !rename || !project.isGeneral else { return }
        projectEditorRename = rename; projectNameDraft = rename ? project.name : ""; projectEditorError = nil; showProjectEditor = true
    }
    func saveProjectEditor() async {
        guard !projectSaving, let current = currentProject else { return }
        projectSaving = true; projectEditorError = nil
        do {
            try await persistProjectSettings()
            let body = try JSONSerialization.data(withJSONObject: ["name": projectNameDraft])
            let data = try await BackendProcess.shared.request(projectEditorRename ? "/api/projects/" + current.id : "/api/projects", method: projectEditorRename ? "PATCH" : "POST", body: body, timeout: 120)
            let project = try JSONDecoder().decode(ProjectOption.self, from: data)
            await loadProjects(); showProjectEditor = false; projectSaving = false
            if projectEditorRename { currentProject = project }
            else { await switchProject(project.id) }
        } catch { projectSaving = false; projectEditorError = error.localizedDescription }
    }
    func chooseFiles() {
        guard !projectBusy else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.resolvesAliases = false; panel.prompt = "Добавить"; panel.message = "Выберите файлы или папки"
        if panel.runModal() == .OK { Task { await upload(panel.urls) } }
    }
    func upload(_ urls: [URL]) async {
        guard !uploading, !projectBusy else { return }; uploading = true; uploadProgress = "Читаю папки…"
        let projectID = currentProjectID
        defer { uploading = false; uploadProgress = "" }
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        let selection = await Task.detached { MaterialImport.collect(urls) }.value
        guard !selection.files.isEmpty else { message = selection.errors.first ?? "В папке нет поддерживаемых файлов"; return }
        do {
            var position = 0, errors = selection.errors
            while position < selection.files.count {
                var batch: [ImportItem] = [], bytes = 0
                while position < selection.files.count && batch.count < 20 {
                    let file = selection.files[position]
                    if bytes + file.size > 8 * 1024 * 1024 && !batch.isEmpty { break }
                    batch.append(file); bytes += file.size; position += 1
                }
                uploadProgress = "Добавляю \(position) из \(selection.files.count)…"
                let boundary = "Dialog-" + UUID().uuidString; var body = Data()
                for item in batch {
                    let data = try Data(contentsOf: item.url)
                    let name = item.url.lastPathComponent.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
                    body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)); body.append(data); body.append(Data("\r\n".utf8))
                }
                let paths = try JSONEncoder().encode(batch.map(\.path))
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"relativePaths\"\r\n\r\n".utf8)); body.append(paths)
                body.append(Data("\r\n--\(boundary)--\r\n".utf8))
                let data = try await BackendProcess.shared.request(projectPath("materials", id: projectID), method: "POST", body: body, contentType: "multipart/form-data; boundary=\(boundary)", timeout: 120)
                if let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], let problems = value["errors"] as? [String] { errors.append(contentsOf: problems) }
            }
            await loadMaterials()
            if !errors.isEmpty { message = errors.prefix(6).joined(separator: "\n") + (errors.count > 6 ? "\nЕщё ошибок: \(errors.count - 6)" : "") }
        } catch { await loadMaterials(); message = error.localizedDescription }
    }
    func deleteMaterial(_ id: String, projectID: String? = nil) async { do { _ = try await BackendProcess.shared.request(projectPath("materials/" + id, id: projectID ?? currentProjectID), method: "DELETE"); await loadMaterials() } catch { message = error.localizedDescription } }
    func login() async {
        do { let data = try await BackendProcess.shared.request("/api/login", method: "POST"); if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let link = object["url"] as? String, let url = URL(string: link) { NSWorkspace.shared.open(url) } }
        catch { message = error.localizedDescription }
    }
    func retrySpeech() async { do { _ = try await BackendProcess.shared.request("/api/speech/retry", method: "POST"); await refreshStatus() } catch { message = error.localizedDescription } }
    @discardableResult func copyAnswer() -> Bool {
        guard !answer.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(answer, forType: .string)
    }
    func exportSession() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Диалог.md"; panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let lines = ["# Диалог", Date().formatted(), "\n## Расшифровка"] + transcript.map { "\n**\($0.source == "remote" ? "Собеседник" : "Я"):** \($0.text)" } + ["\n## Ответы"] + records.map { "\n### \($0.question)\n\n\($0.text)" }
        do { try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8) } catch { message = error.localizedDescription }
    }
    func shutdown() { receiver?.cancel(); poller?.cancel(); reconnect?.cancel(); websocket?.cancel(with: .goingAway, reason: nil); BackendProcess.shared.stop() }
}

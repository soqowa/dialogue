import Foundation

final class BackendProcess {
    static let shared = BackendProcess()
    private var process: Process?
    let port = Int(ProcessInfo.processInfo.environment["DIALOG_PORT"] ?? "4317") ?? 4317
    var base: URL { URL(string: "http://127.0.0.1:\(port)")! }
    private var bundledRoot: URL? {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Service"),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("server/index.mjs").path) else { return nil }
        return folder
    }
    var root: URL {
        if let override = ProcessInfo.processInfo.environment["DIALOG_PROJECT_ROOT"] { return URL(fileURLWithPath: override) }
        if let bundledRoot { return bundledRoot }
        if let file = Bundle.main.url(forResource: "project-root", withExtension: "txt"),
           let text = try? String(contentsOf: file, encoding: .utf8) {
            return URL(fileURLWithPath: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        #if DEBUG
        // Running from Xcode or `swift run`: the sources sit inside the project.
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #else
        // Release binaries never embed the build machine's source path.
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        #endif
    }
    var dataRoot: URL {
        if let override = ProcessInfo.processInfo.environment["DIALOG_DATA_DIR"] { return URL(fileURLWithPath: override) }
        if bundledRoot != nil {
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Dialog", isDirectory: true)
        }
        return root.appendingPathComponent(".local", isDirectory: true)
    }
    func ensureRunning() async throws {
        if let data = try? await request("/api/status") {
            if let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any], (status["protocolVersion"] as? Int ?? 0) >= 5 { return }
            throw DialogError.message("Ещё работает старая версия сервиса. Завершите старое приложение «Диалог» через ⌘Q и откройте новую сборку.")
        }
        let script = root.appendingPathComponent("server/index.mjs")
        guard FileManager.default.fileExists(atPath: script.path) else { throw DialogError.message("Не найден сервис приложения. Переустановите «Диалог».") }
        let p = Process()
        let runtime = Bundle.main.resourceURL?.appendingPathComponent("Runtime", isDirectory: true)
        let node = runtime?.appendingPathComponent("node/bin/node")
        if let node, FileManager.default.isExecutableFile(atPath: node.path) {
            p.executableURL = node; p.arguments = [script.path]
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["node", script.path]
        }
        p.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        env["PORT"] = String(port)
        env["DIALOG_DATA_DIR"] = dataRoot.path
        if bundledRoot != nil, let runtime {
            env["DIALOG_PYTHON"] = runtime.appendingPathComponent("python/bin/python3.11").path
            env["DIALOG_CODEX_BIN"] = runtime.appendingPathComponent("codex/bin/codex").path
            env["DIALOG_VAD_MODEL"] = Bundle.main.resourceURL?.appendingPathComponent("Models/silero_vad.onnx").path
            env["PYTHONNOUSERSITE"] = "1"; env["PYTHONDONTWRITEBYTECODE"] = "1"
            env["SSL_CERT_FILE"] = runtime.appendingPathComponent("python/lib/python3.11/site-packages/certifi/cacert.pem").path
            env["PATH"] = runtime.appendingPathComponent("node/bin").path + ":" + (env["PATH"] ?? "")
        }
        if let executable = Bundle.main.executableURL {
            env["DIALOG_SPEECH_HELPER"] = executable.deletingLastPathComponent().appendingPathComponent("DialogSpeech").path
        }
        p.environment = env
        let logs = dataRoot.appendingPathComponent("native-backend.log")
        try FileManager.default.createDirectory(at: logs.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logs.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logs)
        p.standardOutput = handle; p.standardError = handle
        try p.run(); process = p
        for _ in 0..<100 {
            if !p.isRunning { throw DialogError.message("Сервис не запустился. Подробности: \(logs.path)") }
            if (try? await request("/api/status")) != nil { return }
            try await Task.sleep(for: .milliseconds(300))
        }
        throw DialogError.message("Не удалось подключиться к локальному сервису.")
    }
    func request(_ path: String, method: String = "GET", body: Data? = nil, contentType: String = "application/json", timeout: TimeInterval = 15) async throws -> Data {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method; req.httpBody = body; req.timeoutInterval = timeout
        if body != nil { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw DialogError.message(object?["error"] as? String ?? "Ошибка локального сервиса")
        }
        return data
    }
    func stop() { process?.terminate(); process = nil }
}

enum DialogError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

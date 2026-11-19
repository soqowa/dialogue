import Foundation
import FluidAudio

private final class ProtocolOutput: @unchecked Sendable {
    private let lock = NSLock()
    func send(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardOutput.write(data + Data([10]))
    }
}

@main struct DialogSpeech {
    static func main() async {
        let output = ProtocolOutput()
        do {
            output.send(["type": "speech.loading", "engine": "parakeet", "detail": "Загрузка Parakeet v3…"])
            // Same FluidAudio revision and model cache as SuperDictate 0.2.21.
            let directory = try await AsrModels.download(version: .v3)
            let models = try await AsrModels.load(from: directory, version: .v3)
            let recognizer = AsrManager(config: .default, models: models)
            output.send(["type": "speech.ready", "engine": "parakeet"])
            // Await each job before reading the next one: CoreML inference stays serial.
            while let line = readLine() {
                guard let data = line.data(using: .utf8),
                      let job = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                do {
                    guard let encoded = job["audio"] as? String, let pcm = Data(base64Encoded: encoded), pcm.count % 2 == 0 else {
                        throw NSError(domain: "DialogSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: "Некорректный PCM"])
                    }
                    let samples: [Float] = pcm.withUnsafeBytes { bytes in
                        (0..<(bytes.count / 2)).map { Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768 }
                    }
                    let began = Date()
                    var state = try TdtDecoderState()
                    let language = (job["language"] as? String).flatMap(Language.init(rawValue:))
                    let result = try await recognizer.transcribe(samples, decoderState: &state, language: language)
                    var response = job
                    response.removeValue(forKey: "audio")
                    response["type"] = "transcript"
                    response["text"] = result.text
                    response["ms"] = Int(Date().timeIntervalSince(began) * 1000)
                    output.send(response)
                } catch {
                    output.send(["type": "speech.job_error", "message": error.localizedDescription, "id": job["id"] ?? ""])
                }
            }
        } catch {
            output.send(["type": "speech.error", "message": error.localizedDescription])
        }
    }
}

import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

struct AudioApp: Identifiable { let id: Int32; let name: String }

/// Each physical source owns its own converter and VAD state. Speaker labels never
/// depend on voice identification and overlapping speech stays on separate tracks.
final class PCMProcessor: @unchecked Sendable {
    let source: String
    let pause: Int
    var onAudio: ((String, String, Data, Bool, TimeInterval) -> Void)?
    var onLevel: ((String, Float) -> Void)?
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var inputFormat: AVAudioFormat?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var frame: [Float] = [], pre: [Float] = [], segment: [Float] = []
    private var active = false, silence = 0, voiced = 0, sent = 0, frameCounter = 0
    private var id = UUID().uuidString
    private var began: TimeInterval = 0
    init(source: String, pause: Int) { self.source = source; self.pause = pause }
    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if inputFormat != buffer.format { inputFormat = buffer.format; converter = AVAudioConverter(from: buffer.format, to: target) }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var used = false; var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, state in
            if used { state.pointee = .noDataNow; return nil }
            used = true; state.pointee = .haveData; return buffer
        }
        guard result != .error, let samples = output.floatChannelData?[0] else { return }
        for i in 0..<Int(output.frameLength) {
            frame.append(samples[i])
            if frame.count == 320 { consumeFrame(frame); frame.removeAll(keepingCapacity: true) }
        }
    }
    private func consumeFrame(_ samples: [Float]) {
        let rms = sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
        frameCounter += 1; if frameCounter % 5 == 0 { onLevel?(source, rms) }
        if !active {
            pre.append(contentsOf: samples); if pre.count > 6400 { pre.removeFirst(pre.count - 6400) }
            guard rms >= 0.009 else { return }
            active = true; id = UUID().uuidString; segment = pre; pre = []; sent = 0
            began = Date().timeIntervalSince1970 - Double(segment.count) / 16000
        } else { segment.append(contentsOf: samples) }
        if rms >= 0.009 { voiced += samples.count; silence = 0 } else { silence += samples.count }
        if silence >= pause * 16 || segment.count >= 288000 { finishSegment() }
        else if segment.count - sent >= 32000 { publish(final: false) }
    }
    private func publish(final: Bool) {
        guard segment.count >= 4000, voiced >= 1600 else { return }
        let values = segment.map { Int16((max(-1, min(1, $0)) * 32767).rounded()).littleEndian }
        let data = values.withUnsafeBytes { Data($0) }
        onAudio?(source, id, data, final, began); sent = segment.count
    }
    private func finishSegment() {
        if active { publish(final: true) }
        active = false; segment.removeAll(keepingCapacity: true); silence = 0; voiced = 0; sent = 0
    }
    @discardableResult func flush() -> String? {
        lock.lock(); defer { lock.unlock() }
        let publishedID = active && segment.count >= 4000 && voiced >= 1600 ? id : nil
        finishSegment()
        return publishedID
    }
    func resetInput() {
        lock.lock(); defer { lock.unlock() }
        finishSegment(); frame.removeAll(keepingCapacity: true); pre.removeAll(keepingCapacity: true)
        converter = nil; inputFormat = nil; frameCounter = 0
        onLevel?(source, 0)
    }
}

final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onAudio: ((String, String, Data, Bool, TimeInterval) -> Void)?
    var onLevel: ((String, Float) -> Void)?
    var onStopped: ((String) -> Void)?
    var onMicrophoneState: ((String?, String?) -> Void)?
    private var stream: SCStream?
    private var microphoneCapture: MicrophoneCapture?
    private var remote: PCMProcessor?
    private var mic: PCMProcessor?
    private let queue = DispatchQueue(label: "dev.dialog.system-audio", qos: .userInitiated)
    private var stopping = false
    static func applications() async throws -> [AudioApp] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        return content.applications.filter { $0.processID != ProcessInfo.processInfo.processIdentifier }.map { AudioApp(id: $0.processID, name: $0.applicationName) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    func start(microphone: Bool, microphoneUID: String? = nil, application: Int32, pause: Int) async throws {
        stopping = false
        if microphone {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard allowed else { throw DialogError.message("Разрешите микрофон: Системные настройки → Конфиденциальность и безопасность → Микрофон. Можно также отключить запись своего голоса.") }
        }
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) }
        catch { throw DialogError.message("Разрешите «Диалог» запись экрана и системного аудио в Системных настройках → Конфиденциальность и безопасность. После разрешения перезапустите приложение.\n\n\(error.localizedDescription)") }
        guard let display = content.displays.first else { throw DialogError.message("Не найден доступный дисплей") }
        let filter: SCContentFilter
        if application != 0 {
            guard let selected = content.applications.first(where: { $0.processID == application }) else { throw DialogError.message("Выбранное приложение закрыто. Обновите список источников или выберите весь звук компьютера.") }
            filter = SCContentFilter(display: display, including: [selected], exceptingWindows: [])
        } else {
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        }
        let configuration = SCStreamConfiguration()
        configuration.width = 2; configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.capturesAudio = true; configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 16000; configuration.channelCount = 1
        configuration.showsCursor = false; configuration.queueDepth = 3
        remote = PCMProcessor(source: "remote", pause: pause); remote?.onAudio = onAudio; remote?.onLevel = onLevel
        let capture = SCStream(filter: filter, configuration: configuration, delegate: self)
        // Only audio is consumed; no screen frames are recorded or transmitted.
        try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        stream = capture; try await capture.startCapture()
        if microphone {
            let processor = PCMProcessor(source: "mic", pause: pause); processor.onAudio = onAudio; processor.onLevel = onLevel; mic = processor
            let input = MicrophoneCapture(); input.onState = onMicrophoneState; microphoneCapture = input
            try await input.start(uid: microphoneUID, processor: processor)
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let description = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let result = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        if result == noErr { remote?.consume(buffer) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { if !stopping { onStopped?("Передача системного звука остановилась: \(error.localizedDescription)") } }
    func stop() async {
        stopping = true
        await microphoneCapture?.stop(); microphoneCapture = nil
        if let stream { try? await stream.stopCapture() }; stream = nil
        queue.sync { _ = remote?.flush() }; mic?.flush(); remote = nil; mic = nil
    }
    func finishUtterances() -> Set<String> { Set([remote?.flush(), mic?.flush()].compactMap { $0 }) }
}

import AVFoundation
import AudioToolbox
import CoreAudio

struct MicrophoneDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum MicrophoneDevices {
    static func available() -> [MicrophoneDevice] {
        var address = property(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let result = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!) }
        guard result == noErr else { return [] }
        return ids.compactMap { id in
            var streams = property(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return MicrophoneDevice(id: id, uid: uid, name: name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func defaultID() -> AudioDeviceID? {
        var address = property(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func resolve(uid: String?, devices: [MicrophoneDevice], defaultID: AudioDeviceID?) throws -> MicrophoneDevice {
        if let uid, !uid.isEmpty {
            guard let device = devices.first(where: { $0.uid == uid }) else { throw DialogError.message("Выбранный микрофон отключён. Подключи его или выбери другой в настройках «Диалога».") }
            return device
        }
        guard let device = devices.first(where: { $0.id == defaultID }) else { throw DialogError.message("Микрофон недоступен. Выбери устройство в настройках «Диалога».") }
        return device
    }

    static func property(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = property(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

protocol MicrophoneEngine: AnyObject {
    var notificationObject: AnyObject { get }
    var isRunning: Bool { get }
    func start(device: AudioDeviceID, processor: PCMProcessor) throws
    func stop()
}

private final class HardwareMicrophoneEngine: MicrophoneEngine {
    private let engine = AVAudioEngine()
    private var tapped = false
    var notificationObject: AnyObject { engine }
    var isRunning: Bool { engine.isRunning }

    func start(device: AudioDeviceID, processor: PCMProcessor) throws {
        let input = engine.inputNode
        // Change this audio unit's input only. Never change the system default,
        // the hardware sample rate, or the device's exclusive (hog) mode.
        try input.auAudioUnit.setDeviceID(device)
        let hardwareFormat = input.inputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: hardwareFormat.sampleRate, channels: hardwareFormat.channelCount) else { throw DialogError.message("Микрофон пока недоступен. Подожди завершения подключения к звонку.") }
        // The output bus may still hold the previous Bluetooth device's format.
        // Rebuild the tap at the selected device's actual hardware rate.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in processor.consume(buffer) }
        tapped = true
        do { engine.prepare(); try engine.start() }
        catch { stop(); throw error }
    }

    func stop() {
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        engine.stop()
    }
}

/// Serializes device changes away from AVAudioEngine's internal notification
/// thread. A stopped input is rebuilt without interrupting system-audio capture.
final class MicrophoneCapture: @unchecked Sendable {
    var onState: ((String?, String?) -> Void)?
    private let queue = DispatchQueue(label: "dev.dialog.microphone-control", qos: .userInitiated)
    private let devices: () -> [MicrophoneDevice]
    private let defaultDevice: () -> AudioDeviceID?
    private let makeEngine: () -> MicrophoneEngine
    private let center: NotificationCenter
    private let observeHardware: Bool
    private let retryDelay: TimeInterval
    private var active = false
    private var uid: String?
    private var processor: PCMProcessor?
    private var engine: MicrophoneEngine?
    private var currentDevice: AudioDeviceID?
    private var observer: NSObjectProtocol?
    private var hardwareListener: AudioObjectPropertyListenerBlock?
    private var recovery: DispatchWorkItem?
    private var retry = 0

    init(devices: @escaping () -> [MicrophoneDevice] = MicrophoneDevices.available,
         defaultDevice: @escaping () -> AudioDeviceID? = MicrophoneDevices.defaultID,
         makeEngine: @escaping () -> MicrophoneEngine = { HardwareMicrophoneEngine() },
         center: NotificationCenter = .default, observeHardware: Bool = true, retryDelay: TimeInterval = 0.35) {
        self.devices = devices; self.defaultDevice = defaultDevice; self.makeEngine = makeEngine
        self.center = center; self.observeHardware = observeHardware; self.retryDelay = retryDelay
    }

    func start(uid: String?, processor: PCMProcessor) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.uid = uid; self.processor = processor; self.active = true
                do { try self.openEngine(); self.watchHardware(); continuation.resume() }
                catch { self.active = false; self.closeEngine(); self.processor = nil; continuation.resume(throwing: error) }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.active = false; self.recovery?.cancel(); self.recovery = nil
                self.unwatchHardware(); self.closeEngine(); self.processor?.resetInput(); self.processor = nil
                self.onState?(nil, nil); continuation.resume()
            }
        }
    }

    private func openEngine() throws {
        guard let processor else { return }
        let device = try MicrophoneDevices.resolve(uid: uid, devices: devices(), defaultID: defaultDevice())
        let candidate = makeEngine()
        do { try candidate.start(device: device.id, processor: processor) }
        catch { candidate.stop(); throw error }
        engine = candidate; currentDevice = device.id
        observer = center.addObserver(forName: .AVAudioEngineConfigurationChange, object: candidate.notificationObject, queue: nil) { [weak self, weak candidate] _ in
            // Never tear down an engine inside its configuration notification.
            self?.queue.async { [weak self, weak candidate] in
                guard let self, let candidate, self.engine === candidate, !candidate.isRunning else { return }
                self.scheduleRecovery()
            }
        }
        retry = 0; onState?(device.name, nil)
    }

    private func closeEngine() {
        if let observer { center.removeObserver(observer) }; observer = nil
        engine?.stop(); engine = nil; currentDevice = nil
    }

    private func scheduleRecovery() {
        guard active, recovery == nil else { return }
        onState?(nil, "Переподключаю микрофон…")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }; self.recovery = nil
            guard self.active else { return }
            self.closeEngine(); self.processor?.resetInput()
            do { try self.openEngine() }
            catch {
                self.retry += 1
                if self.retry < 6 { self.scheduleRecovery() }
                else { self.onState?(nil, "Микрофон недоступен. \(error.localizedDescription)") }
            }
        }
        recovery = work; queue.asyncAfter(deadline: .now() + retryDelay, execute: work)
    }

    private func watchHardware() {
        guard observeHardware, hardwareListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.active else { return }
            let desired = try? MicrophoneDevices.resolve(uid: self.uid, devices: self.devices(), defaultID: self.defaultDevice())
            if desired?.id != self.currentDevice || self.engine == nil { self.retry = 0; self.scheduleRecovery() }
        }
        hardwareListener = listener
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var address = MicrophoneDevices.property(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        }
    }

    private func unwatchHardware() {
        guard let listener = hardwareListener else { return }
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var address = MicrophoneDevices.property(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        }
        hardwareListener = nil
    }
}

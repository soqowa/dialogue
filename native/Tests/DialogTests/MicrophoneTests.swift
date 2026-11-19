import XCTest
import AVFoundation
@testable import Dialog

final class MicrophoneTests: XCTestCase {
    private let mac = MicrophoneDevice(id: 11, uid: "built-in", name: "MacBook Pro Microphone")
    private let headset = MicrophoneDevice(id: 22, uid: "bluetooth", name: "WH-1000XM6")

    func testExplicitMicrophoneDoesNotFollowSystemDefault() throws {
        let selected = try MicrophoneDevices.resolve(uid: mac.uid, devices: [mac, headset], defaultID: headset.id)
        XCTAssertEqual(selected, mac)
        XCTAssertEqual(try MicrophoneDevices.resolve(uid: nil, devices: [mac, headset], defaultID: headset.id), headset)
    }

    func testDisconnectedMicrophoneDoesNotSilentlySwitchToAnother() {
        XCTAssertThrowsError(try MicrophoneDevices.resolve(uid: mac.uid, devices: [headset], defaultID: headset.id))
    }

    func testLegacyPreferencesKeepTheirValuesWithoutMicrophoneSelection() throws {
        var saved = Preferences(); saved.style = "Инструкции"; saved.fontSize = 14; saved.auto = false
        let data = try JSONEncoder().encode(saved)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "microphoneUID")
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(restored.microphoneUID)
        XCTAssertEqual(restored.style, saved.style); XCTAssertEqual(restored.fontSize, 14); XCTAssertFalse(restored.auto)
    }

    func testConfigurationChangeReopensSameSelectedInput() async throws {
        let center = NotificationCenter(), hardware = FakeHardware()
        let restored = expectation(description: "microphone restored")
        let selected = mac
        let capture = MicrophoneCapture(devices: { [selected] }, defaultDevice: { 22 }, makeEngine: { hardware.make() }, center: center, observeHardware: false, retryDelay: 0.01)
        capture.onState = { name, issue in if name != nil, issue == nil, hardware.count == 2 { restored.fulfill() } }
        try await capture.start(uid: mac.uid, processor: PCMProcessor(source: "mic", pause: 700))
        let first = try XCTUnwrap(hardware.first)
        first.simulateConfigurationChange(center)
        await fulfillment(of: [restored], timeout: 2)
        XCTAssertEqual(hardware.selectedDevices, [mac.id, mac.id])
        XCTAssertTrue(first.stopped)
        await capture.stop()
    }

    func testStoppingCancelsPendingReconnection() async throws {
        let center = NotificationCenter(), hardware = FakeHardware(), selected = mac
        let capture = MicrophoneCapture(devices: { [selected] }, defaultDevice: { selected.id }, makeEngine: { hardware.make() }, center: center, observeHardware: false, retryDelay: 0.10)
        try await capture.start(uid: nil, processor: PCMProcessor(source: "mic", pause: 700))
        let first = try XCTUnwrap(hardware.first)
        first.simulateConfigurationChange(center)
        await capture.stop()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(hardware.count, 1)
        XCTAssertTrue(first.stopped)
    }

    func testRecoveryFailureIsReportedWithoutReplacingSelectedMicrophone() async throws {
        let center = NotificationCenter(), hardware = FakeHardware(), selected = mac
        let failed = expectation(description: "unavailable microphone reported")
        let capture = MicrophoneCapture(devices: { hardware.count == 0 ? [selected] : [] }, defaultDevice: { 22 }, makeEngine: { hardware.make() }, center: center, observeHardware: false, retryDelay: 0.01)
        capture.onState = { _, issue in if issue?.hasPrefix("Микрофон недоступен.") == true { failed.fulfill() } }
        try await capture.start(uid: mac.uid, processor: PCMProcessor(source: "mic", pause: 700))
        try XCTUnwrap(hardware.first).simulateConfigurationChange(center)
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(hardware.selectedDevices, [mac.id])
        await capture.stop()
    }
}

private final class FakeHardware {
    private let lock = NSLock()
    private var engines: [FakeMicrophoneEngine] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return engines.count }
    var first: FakeMicrophoneEngine? { lock.lock(); defer { lock.unlock() }; return engines.first }
    var selectedDevices: [UInt32] { lock.lock(); defer { lock.unlock() }; return engines.compactMap(\.device) }
    func make() -> MicrophoneEngine {
        lock.lock(); defer { lock.unlock() }
        let engine = FakeMicrophoneEngine(); engines.append(engine); return engine
    }
}

private final class FakeMicrophoneEngine: NSObject, MicrophoneEngine {
    private let lock = NSLock()
    private var running = false, didStop = false
    private var selected: UInt32?
    var notificationObject: AnyObject { self }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return didStop }
    var device: UInt32? { lock.lock(); defer { lock.unlock() }; return selected }
    func start(device: UInt32, processor: PCMProcessor) throws { lock.lock(); defer { lock.unlock() }; selected = device; running = true }
    func stop() { lock.lock(); defer { lock.unlock() }; running = false; didStop = true }
    func simulateConfigurationChange(_ center: NotificationCenter) {
        lock.lock(); running = false; lock.unlock()
        center.post(name: .AVAudioEngineConfigurationChange, object: self)
    }
}

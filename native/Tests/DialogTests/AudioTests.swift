import XCTest
import AVFoundation
@testable import Dialog

final class AudioTests: XCTestCase {
    private func feed(_ processor: PCMProcessor, seconds: Double, amplitude: Float, rate: Double = 48000) {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let count = 960
        for _ in 0..<Int(seconds * rate / Double(count)) {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count { buffer.floatChannelData![0][i] = sin(Float(i) * 0.3) * amplitude }
            processor.consume(buffer)
        }
    }
    func testSilenceProducesNoRequests() {
        let processor = PCMProcessor(source: "remote", pause: 480)
        var requests = 0; processor.onAudio = { _, _, _, _, _ in requests += 1 }
        feed(processor, seconds: 3, amplitude: 0); processor.flush()
        XCTAssertEqual(requests, 0)
    }
    func testResamplingPartialsAndFinal() {
        let processor = PCMProcessor(source: "remote", pause: 480)
        var chunks: [(String, Data, Bool)] = []
        processor.onAudio = { _, id, data, final, _ in chunks.append((id, data, final)) }
        feed(processor, seconds: 2, amplitude: 0.1); feed(processor, seconds: 0.8, amplitude: 0)
        XCTAssertTrue(chunks.contains { !$0.2 }); XCTAssertEqual(chunks.filter { $0.2 }.count, 1)
        XCTAssertEqual(Set(chunks.map { $0.0 }).count, 1)
        XCTAssertGreaterThan(chunks.last!.1.count, 64000)
        XCTAssertLessThan(chunks.last!.1.count, 85000)
    }
    func testSeparateSourcesKeepDistinctUtteranceIDs() {
        let a = PCMProcessor(source: "remote", pause: 480), b = PCMProcessor(source: "mic", pause: 480)
        var results: [(String, String)] = []
        let handler: (String, String, Data, Bool, TimeInterval) -> Void = { source, id, _, final, _ in if final { results.append((source, id)) } }
        a.onAudio = handler; b.onAudio = handler
        feed(a, seconds: 0.7, amplitude: 0.1); feed(b, seconds: 0.7, amplitude: 0.1); a.flush(); b.flush()
        XCTAssertEqual(results.map { $0.0 }, ["remote", "mic"])
        XCTAssertNotEqual(results[0].1, results[1].1)
    }
    func testShortcutFlushFinalizesOnceAndRecordingCanContinue() {
        let processor = PCMProcessor(source: "remote", pause: 700)
        var finals: [String] = []
        processor.onAudio = { _, id, _, final, _ in if final { finals.append(id) } }
        feed(processor, seconds: 0.6, amplitude: 0.1)
        let first = processor.flush()
        XCTAssertEqual(finals, [first!]); XCTAssertNil(processor.flush())
        feed(processor, seconds: 0.6, amplitude: 0.1)
        let second = processor.flush()
        XCTAssertEqual(finals.count, 2); XCTAssertNotEqual(first, second)
    }
    func testDeviceFormatChangeSeparatesUtterancesAndResetsMeter() {
        let processor = PCMProcessor(source: "mic", pause: 700)
        var finals: [String] = [], lastLevel: Float = 1
        processor.onAudio = { _, id, _, final, _ in if final { finals.append(id) } }
        processor.onLevel = { _, level in lastLevel = level }
        feed(processor, seconds: 0.6, amplitude: 0.1, rate: 48000)
        processor.resetInput()
        XCTAssertEqual(finals.count, 1); XCTAssertEqual(lastLevel, 0)
        feed(processor, seconds: 0.6, amplitude: 0.1, rate: 16000)
        processor.flush()
        XCTAssertEqual(finals.count, 2); XCTAssertNotEqual(finals[0], finals[1])
    }
}

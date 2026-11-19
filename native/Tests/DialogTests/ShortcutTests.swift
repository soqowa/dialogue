import XCTest
import AppKit
import Carbon
@testable import Dialog

final class ShortcutTests: XCTestCase {
    func testOlderPreferencesKeepTheirSettingsWithoutANewShortcutField() throws {
        var original = Preferences(); original.auto = false; original.style = "Мои инструкции"; original.sessionID = "existing-session"
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        object.removeValue(forKey: "answerShortcut")
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(restored.auto); XCTAssertEqual(restored.style, original.style); XCTAssertEqual(restored.sessionID, original.sessionID)
        XCTAssertNil(restored.answerShortcut)
    }
    func testRecordedShortcutStoresPhysicalKeyAndModifiers() throws {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option], timestamp: 0,
                                    windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        let shortcut = AnswerShortcut(event: event)
        XCTAssertEqual(shortcut, .default); XCTAssertEqual(shortcut.display, "⌃⌥↩")
        XCTAssertEqual(try JSONDecoder().decode(AnswerShortcut.self, from: JSONEncoder().encode(shortcut)), shortcut)
    }
    func testSingleLettersSpaceReturnAndFunctionKeysAreAllowed() {
        XCTAssertNil(AnswerShortcut(keyCode: 0, modifiers: 0, key: "A").validationError)
        XCTAssertNil(AnswerShortcut(keyCode: 0, modifiers: UInt32(shiftKey), key: "A").validationError)
        XCTAssertNil(AnswerShortcut(keyCode: 49, modifiers: 0, key: "Space").validationError)
        XCTAssertNil(AnswerShortcut(keyCode: 36, modifiers: 0, key: "↩").validationError)
        XCTAssertNotNil(AnswerShortcut(keyCode: 12, modifiers: UInt32(cmdKey), key: "Q").validationError)
        XCTAssertNil(AnswerShortcut(keyCode: 100, modifiers: 0, key: "F8").validationError)
    }
    @MainActor func testSystemHotKeyEventsTriggerOnceUntilReleased() throws {
        _ = NSApplication.shared
        let shortcut = GlobalAnswerShortcut()
        let key = AnswerShortcut(keyCode: 90, modifiers: UInt32(controlKey | optionKey), key: "F20")
        if let error = shortcut.register(key) { throw XCTSkip(error) }
        var calls = 0; shortcut.onPress = { calls += 1 }
        func dispatch(_ kind: UInt32) throws {
            var event: EventRef?
            XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), kind, GetCurrentEventTime(), EventAttributes(kEventAttributeUserEvent), &event), noErr)
            let value = try XCTUnwrap(event); defer { ReleaseEvent(value) }
            var id = EventHotKeyID(signature: 0x446c6741, id: 1)
            XCTAssertEqual(SetEventParameter(value, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id), noErr)
            XCTAssertEqual(SendEventToEventTarget(value, GetEventDispatcherTarget()), noErr)
        }
        try dispatch(UInt32(kEventHotKeyPressed)); try dispatch(UInt32(kEventHotKeyPressed))
        XCTAssertEqual(calls, 1)
        try dispatch(UInt32(kEventHotKeyReleased)); try dispatch(UInt32(kEventHotKeyPressed))
        XCTAssertEqual(calls, 2)
    }
    @MainActor func testConflictingRegistrationRestoresThePreviousShortcut() throws {
        _ = NSApplication.shared
        let a = GlobalAnswerShortcut(), b = GlobalAnswerShortcut()
        let first = AnswerShortcut(keyCode: 90, modifiers: UInt32(controlKey | optionKey), key: "F20")
        let second = AnswerShortcut(keyCode: 80, modifiers: UInt32(controlKey | optionKey), key: "F19")
        if let error = a.register(first) { throw XCTSkip(error) }
        if let error = b.register(second) { throw XCTSkip(error) }
        XCTAssertNotNil(b.register(first)); XCTAssertEqual(b.shortcut, second)
    }
    func testRightCommandTapIsDifferentFromLeftCommandAndFiresOnceOnRelease() {
        var state = ModifierTapState(keyCode: 54)
        XCTAssertFalse(state.flagsChanged(0x100008)); XCTAssertFalse(state.flagsChanged(0))
        XCTAssertFalse(state.flagsChanged(0x100010)); XCTAssertFalse(state.flagsChanged(0x100010))
        XCTAssertTrue(state.flagsChanged(0)); XCTAssertFalse(state.flagsChanged(0))
    }
    func testModifierChordsAndClicksDoNotTriggerAnAnswer() {
        var state = ModifierTapState(keyCode: 54)
        XCTAssertFalse(state.flagsChanged(0x100010)); state.cancelChord() // ⌘C or a click
        XCTAssertFalse(state.flagsChanged(0))
        XCTAssertFalse(state.flagsChanged(0x100010)); XCTAssertFalse(state.flagsChanged(0x120012)) // + Shift
        XCTAssertFalse(state.flagsChanged(0x100010)); XCTAssertFalse(state.flagsChanged(0))
        XCTAssertFalse(state.flagsChanged(0x100018)); XCTAssertFalse(state.flagsChanged(0x100010)) // both Commands
        XCTAssertFalse(state.flagsChanged(0))
        XCTAssertFalse(state.flagsChanged(0x100010)); XCTAssertTrue(state.flagsChanged(0))
    }
    @MainActor func testRecorderAcceptsRightCommandAfterReleaseAndStillRecordsCommandChords() throws {
        _ = NSApplication.shared
        let button = AnswerShortcutRecorder.RecorderButton()
        var recorded: [AnswerShortcut] = []
        button.onChange = { recorded.append($0) }
        func flags(_ raw: UInt) -> NSEvent {
            NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: raw), timestamp: 0,
                             windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 54)!
        }
        button.beginRecording(); button.flagsChanged(with: flags(0x100010))
        XCTAssertTrue(button.recording); XCTAssertTrue(recorded.isEmpty)
        button.flagsChanged(with: flags(0))
        XCTAssertFalse(button.recording); XCTAssertEqual(recorded.count, 1)
        XCTAssertTrue(recorded[0].isModifierOnly); XCTAssertEqual(recorded[0].display, "Правый ⌘")
        XCTAssertEqual(try JSONDecoder().decode(AnswerShortcut.self, from: JSONEncoder().encode(recorded[0])), recorded[0])
        button.beginRecording(); button.flagsChanged(with: flags(0x100010))
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                                  characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40)!
        button.keyDown(with: key)
        XCTAssertFalse(button.recording); XCTAssertEqual(recorded.count, 2)
        XCTAssertFalse(recorded[1].isModifierOnly); XCTAssertEqual(recorded[1].display, "⌘K")
    }
}

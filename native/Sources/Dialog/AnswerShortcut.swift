import AppKit
import Carbon
import SwiftUI

struct AnswerShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let key: String
    static let `default` = AnswerShortcut(keyCode: 36, modifiers: UInt32(controlKey | optionKey), key: "↩")
    static let functionKeys: Set<UInt32> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
    var isModifierOnly: Bool { modifiers == 0 && ModifierKey.keys[keyCode] != nil }
    var display: String {
        if isModifierOnly { return ModifierKey.keys[keyCode]!.name }
        return [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map { $0.1 }.joined() + key
    }
    var validationError: String? {
        guard keyCode < 128, !key.isEmpty else { return "Не удалось определить клавишу." }
        if modifiers == UInt32(cmdKey), [0, 1, 4, 6, 7, 8, 9, 12, 13, 31, 43, 46, 48, 49].contains(keyCode) {
            return "Это стандартное сочетание macOS. Добавьте ещё один модификатор."
        }
        if keyCode == 15 && modifiers == UInt32(cmdKey | shiftKey) { return "Это сочетание уже запускает и останавливает запись." }
        return nil
    }
    init(keyCode: UInt32, modifiers: UInt32, key: String) { self.keyCode = keyCode; self.modifiers = modifiers; self.key = key }
    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        var flags: UInt32 = 0
        for (flag, carbon) in [(NSEvent.ModifierFlags.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)] {
            if event.modifierFlags.contains(flag) { flags |= UInt32(carbon) }
        }
        modifiers = flags
        let names: [UInt32: String] = [36: "↩", 76: "⌤", 49: "Space", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down"]
        let fKeys: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        key = names[keyCode] ?? fKeys.firstIndex(of: keyCode).map { "F\($0 + 1)" } ?? (event.charactersIgnoringModifiers ?? "").uppercased()
    }
}

/// Registers only the chosen combination with macOS. No keyboard monitoring or window activation.
final class GlobalAnswerShortcut {
    private var handler: EventHandlerRef?
    private var registration: EventHotKeyRef?
    private var modifierMonitor: ModifierAnswerMonitor?
    private(set) var shortcut: AnswerShortcut?
    private var held = false
    var onPress: (() -> Void)?
    private static let signature: OSType = 0x446c6741 // DlgA

    func register(_ value: AnswerShortcut) -> String? {
        if let error = value.validationError { return error }
        if value.isModifierOnly, !ModifierAnswerMonitor.hasAccess {
            suspend(); shortcut = value
            return ModifierAnswerMonitor.accessMessage
        }
        if (registration != nil || modifierMonitor != nil), shortcut == value { return nil }
        if handler == nil {
            var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                         EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            let result = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                      id.signature == GlobalAnswerShortcut.signature, id.id == 1 else { return OSStatus(eventNotHandledErr) }
                let instance = Unmanaged<GlobalAnswerShortcut>.fromOpaque(context).takeUnretainedValue()
                if GetEventKind(event) == UInt32(kEventHotKeyReleased) { instance.held = false }
                else if !instance.held { instance.held = true; instance.onPress?() }
                return noErr
            }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard result == noErr else { return "Не удалось подключить глобальный шорткат (\(result))." }
        }
        let old = shortcut
        suspend()
        if let error = install(value) {
            if let old { _ = install(old) }
            return error
        }
        return nil
    }
    private func install(_ value: AnswerShortcut) -> String? {
        if value.isModifierOnly {
            let monitor = ModifierAnswerMonitor(keyCode: value.keyCode) { [weak self] in self?.onPress?() }
            if let error = monitor.start() { return error }
            modifierMonitor = monitor; shortcut = value
            return nil
        }
        let status = RegisterEventHotKey(value.keyCode, value.modifiers, EventHotKeyID(signature: Self.signature, id: 1), GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &registration)
        if status == noErr { shortcut = value }
        return status == noErr ? nil : "Сочетание занято системой или другим приложением. Выберите другое (\(status))."
    }
    func suspend() {
        if let registration { UnregisterEventHotKey(registration) }
        modifierMonitor?.stop(); modifierMonitor = nil
        registration = nil; held = false
    }
    deinit { suspend(); if let handler { RemoveEventHandler(handler) } }
}

struct AnswerShortcutRecorder: NSViewRepresentable {
    let shortcut: AnswerShortcut
    let onChange: (AnswerShortcut) -> Void
    let onRecording: (Bool) -> Void
    let onError: (String) -> Void
    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.bezelStyle = .rounded; button.setButtonType(.momentaryPushIn)
        button.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        button.target = button; button.action = #selector(RecorderButton.beginRecording)
        button.setAccessibilityLabel("Клавиша ответа")
        return button
    }
    func updateNSView(_ button: RecorderButton, context: Context) {
        button.current = shortcut; button.onChange = onChange; button.onRecording = onRecording; button.onError = onError
        if !button.recording { button.title = shortcut.display }
        button.toolTip = "Нажмите и введите клавишу или сочетание. Esc — отмена."
    }
    static func dismantleNSView(_ button: RecorderButton, coordinator: ()) { button.endRecording() }

    final class RecorderButton: NSButton {
        var current = AnswerShortcut.default
        var onChange: ((AnswerShortcut) -> Void)?
        var onRecording: ((Bool) -> Void)?
        var onError: ((String) -> Void)?
        private(set) var recording = false
        private var keyMonitor: Any?
        private var deactivateObserver: NSObjectProtocol?
        private var pendingModifier: UInt32?
        override var acceptsFirstResponder: Bool { true }
        @objc func beginRecording() {
            guard !recording else { return }
            recording = true; title = "Нажмите клавишу…"; onRecording?(true)
            window?.makeFirstResponder(self)
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                guard let self, self.recording else { return event }
                if event.type == .flagsChanged { self.flagsChanged(with: event) }
                else { self.keyDown(with: event) }
                return nil
            }
            deactivateObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.endRecording()
            }
        }
        func endRecording() {
            guard recording else { return }
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
            if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver); self.deactivateObserver = nil }
            recording = false; pendingModifier = nil; title = current.display; onRecording?(false)
        }
        override func resignFirstResponder() -> Bool { endRecording(); return super.resignFirstResponder() }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if recording, event.type == .keyDown { keyDown(with: event); return true }
            return super.performKeyEquivalent(with: event)
        }
        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            guard !event.isARepeat else { return }
            if event.keyCode == 53 { endRecording(); return }
            pendingModifier = nil
            let candidate = AnswerShortcut(event: event)
            if let error = candidate.validationError { onError?(error); return }
            onChange?(candidate); endRecording()
        }
        override func flagsChanged(with event: NSEvent) {
            guard recording else { super.flagsChanged(with: event); return }
            let code = UInt32(event.keyCode), flags = UInt64(event.modifierFlags.rawValue)
            guard let key = ModifierKey.keys[code] else { pendingModifier = nil; return }
            if key.isPressed(flags) {
                pendingModifier = key.isAlone(flags) ? code : nil
                title = pendingModifier != nil ? "Отпустите \(key.name.lowercased())…" : "Нажмите клавишу…"
            } else if pendingModifier == code, flags & ModifierKey.modifiersMask == 0 {
                onChange?(AnswerShortcut(keyCode: code, modifiers: 0, key: key.name)); endRecording()
            } else { pendingModifier = nil }
        }
    }
}

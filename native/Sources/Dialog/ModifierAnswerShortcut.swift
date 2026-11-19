import AppKit

struct ModifierKey {
    let name: String
    let sideMask: UInt64
    let flag: UInt64
    static let keys: [UInt32: ModifierKey] = [
        54: .init(name: "Правый ⌘", sideMask: 0x10, flag: 0x100000),
        55: .init(name: "Левый ⌘", sideMask: 0x08, flag: 0x100000),
        56: .init(name: "Левый ⇧", sideMask: 0x02, flag: 0x20000),
        60: .init(name: "Правый ⇧", sideMask: 0x04, flag: 0x20000),
        58: .init(name: "Левый ⌥", sideMask: 0x20, flag: 0x80000),
        61: .init(name: "Правый ⌥", sideMask: 0x40, flag: 0x80000),
        59: .init(name: "Левый ⌃", sideMask: 0x01, flag: 0x40000),
        62: .init(name: "Правый ⌃", sideMask: 0x2000, flag: 0x40000),
        63: .init(name: "Fn", sideMask: 0x800000, flag: 0x800000),
    ]
    static let modifiersMask: UInt64 = 0x1e0000 | 0x800000
    static let sidesMask: UInt64 = 0x207f | 0x800000
    func isPressed(_ flags: UInt64) -> Bool { flags & sideMask != 0 }
    func isAlone(_ flags: UInt64) -> Bool {
        isPressed(flags) && flags & Self.modifiersMask == flag && flags & Self.sidesMask == sideMask
    }
}

/// Recognizes a tap on one physical modifier, excluding chords and clicks.
struct ModifierTapState {
    let keyCode: UInt32
    private var down = false
    private var clean = false
    init(keyCode: UInt32) { self.keyCode = keyCode }
    mutating func flagsChanged(_ flags: UInt64) -> Bool {
        guard let key = ModifierKey.keys[keyCode] else { return false }
        if key.isPressed(flags) {
            if !down { down = true; clean = key.isAlone(flags) }
            else if !key.isAlone(flags) { clean = false }
            return false
        }
        let fire = down && clean && flags & ModifierKey.modifiersMask == 0
        down = false; clean = false
        return fire
    }
    mutating func cancelChord() { clean = false }
    mutating func reset() { down = false; clean = false }
}

/// A read-only event tap; key characters are neither read nor stored.
final class ModifierAnswerMonitor {
    static var hasAccess: Bool { CGPreflightListenEventAccess() }
    static let accessMessage = "Для отдельной клавиши-модификатора в фоне разрешите «Диалогу» мониторинг ввода."
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var state: ModifierTapState
    private let onTap: () -> Void
    init(keyCode: UInt32, onTap: @escaping () -> Void) { state = ModifierTapState(keyCode: keyCode); self.onTap = onTap }
    func start() -> String? {
        guard Self.hasAccess else { return Self.accessMessage }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                         eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<ModifierAnswerMonitor>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                monitor.state.reset()
                if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else if type == .flagsChanged {
                if monitor.state.flagsChanged(event.flags.rawValue) { monitor.onTap() }
            } else { monitor.state.cancelChord() }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return "Не удалось включить клавишу в фоне. Проверьте мониторинг ввода и перезапустите «Диалог»."
        }
        self.tap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { stop(); return "Не удалось подключить обработчик клавиши." }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return nil
    }
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; state.reset()
    }
    deinit { stop() }
}

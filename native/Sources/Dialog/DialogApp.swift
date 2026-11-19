import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { BackendProcess.shared.stop() }
}

@main struct DialogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("Диалог") { ContentView().environmentObject(model).preferredColorScheme(.light) }
            .defaultSize(width: 1280, height: 850)
            .commands { CommandGroup(replacing: .appSettings) { Button("Настройки…") { model.settingsTab = 1; model.showSettings = true }.keyboardShortcut(",") }; CommandMenu("Разговор") { Button(model.running ? "Завершить прослушивание" : "Начать слушать") { Task { await model.toggleCapture() } }.keyboardShortcut("r", modifiers: [.command, .shift]); Button("Ответить по диалогу · \(model.answerShortcut.display)") { Task { await model.answerFromConversation() } }.disabled(!model.canAnswerFromConversation); Button("Добавить материалы…") { model.chooseFiles() }.keyboardShortcut("o"); Button("Сохранить диалог…") { model.exportSession() }.keyboardShortcut("s") } }
    }
}

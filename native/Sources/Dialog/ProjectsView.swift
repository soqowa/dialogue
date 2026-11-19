import SwiftUI

struct ProjectOption: Decodable, Identifiable, Equatable {
    let id: String; let name: String; let isGeneral: Bool
}
struct ProjectSettings: Decodable {
    let style: String; let strict: Bool; let model: String; let effort: String
    let lastSessionId: String?
}
struct ProjectDetail: Decodable {
    let id: String; let name: String; let isGeneral: Bool; let settings: ProjectSettings
    var option: ProjectOption { ProjectOption(id: id, name: name, isGeneral: isGeneral) }
}
struct ProjectSnapshot: Decodable {
    let project: ProjectDetail; let projects: [ProjectOption]; let session: ConversationSnapshot; let materials: [Material]
}

struct ProjectMenu: View {
    @EnvironmentObject var app: AppModel
    @State private var expanded = false
    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill").foregroundStyle(DialogPalette.icon)
                Text(app.currentProject?.name ?? "Общее").lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if app.projectBusy { ProgressView().controlSize(.mini) }
                else { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(DialogPalette.muted) }
            }.font(.system(size: 12, weight: .medium)).frame(width: 146)
        }.buttonStyle(DialogButtonStyle())
            .disabled(app.projectBusy || app.uploading || app.starting || !app.online || app.currentProject == nil)
            .accessibilityLabel("Проект: \(app.currentProject?.name ?? "Общее")").accessibilityIdentifier("project.selector")
            .help("Выбрать проект · \(app.currentProject?.name ?? "Общее")")
            .popover(isPresented: $expanded, arrowEdge: .bottom) { dropdown }
            .onChange(of: app.projectBusy) { _, busy in if busy { expanded = false } }
    }
    private var dropdown: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Проекты").font(.system(size: 11, weight: .semibold)).foregroundStyle(DialogPalette.muted).padding(.horizontal, 10).padding(.top, 7).padding(.bottom, 3)
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(app.projects) { project in
                        Button { expanded = false; Task { await app.switchProject(project.id) } } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "folder").foregroundStyle(DialogPalette.muted)
                                Text(project.name).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                if project.id == app.currentProject?.id { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(DialogPalette.ink) }
                            }.font(.system(size: 12)).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(DialogButtonStyle(.row, selected: project.id == app.currentProject?.id))
                            .accessibilityIdentifier("project.option.\(project.id)").help(project.name)
                    }
                }
            }.frame(height: min(CGFloat(app.projects.count) * 47, 235))
            GlassDivider().padding(.vertical, 3)
            dropdownAction("Новый проект", symbol: "plus", rename: false)
            if let current = app.currentProject, !current.isGeneral { dropdownAction("Переименовать", symbol: "pencil", rename: true) }
        }.padding(8).frame(width: 270).foregroundStyle(DialogPalette.ink)
    }
    private func dropdownAction(_ title: String, symbol: String, rename: Bool) -> some View {
        Button {
            expanded = false
            Task { @MainActor in await Task.yield(); app.beginProjectEditor(rename: rename) }
        } label: {
            Label(title, systemImage: symbol).font(.system(size: 12)).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).foregroundStyle(DialogPalette.ink).contentShape(Rectangle())
        }.buttonStyle(DialogButtonStyle(.row)).accessibilityIdentifier(rename ? "project.rename" : "project.create")
    }
}

struct ProjectEditorView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: app.projectEditorRename ? "folder" : "folder.badge.plus").font(.system(size: 20, weight: .regular)).foregroundStyle(DialogPalette.icon)
                    .frame(width: 44, height: 44).liquidGlass(RoundedRectangle(cornerRadius: 13, style: .continuous))
                Text(app.projectEditorRename ? "Название проекта" : "Новый проект").font(.system(size: 23, weight: .semibold)).tracking(-0.5)
                Spacer()
                DialogIconButton(symbol: "xmark", label: "Закрыть окно проекта", glass: true) { dismiss() }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Название проекта").font(.system(size: 12, weight: .medium))
                TextField("Например, собеседование", text: $app.projectNameDraft).textFieldStyle(.plain).font(.system(size: 14)).focused($focused)
                    .padding(.horizontal, 14).frame(height: 42).background(DialogPalette.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(focused ? DialogPalette.accent.opacity(0.7) : DialogPalette.line).allowsHitTesting(false))
                    .tint(DialogPalette.accent).accessibilityLabel("Название проекта").accessibilityIdentifier("project.editor.name")
                    .onSubmit { Task { await app.saveProjectEditor() } }
            }
            if !app.projectEditorRename {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "square.on.square").font(.system(size: 14)).foregroundStyle(DialogPalette.muted).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Материалы и манера ответа из «Общего»").font(.system(size: 12))
                        Text("История начнётся с нового разговора.").font(.system(size: 11)).foregroundStyle(DialogPalette.muted)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if let error = app.projectEditorError { Text(error).font(.system(size: 12)).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.buttonStyle(DialogToolbarButtonStyle()).keyboardShortcut(.cancelAction)
                Button { Task { await app.saveProjectEditor() } } label: {
                    HStack(spacing: 7) { if app.projectSaving { ProgressView().controlSize(.mini) }; Text(app.projectSaving ? "Сохраняю…" : app.projectEditorRename ? "Сохранить" : "Создать проект") }.frame(minWidth: 108)
                }.buttonStyle(DialogToolbarButtonStyle(primary: true)).keyboardShortcut(.defaultAction).accessibilityIdentifier("project.editor.save")
                    .disabled(app.projectNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 460).dialogSheet()
            .disabled(app.projectSaving).interactiveDismissDisabled(app.projectSaving).onAppear { focused = true }
    }
}

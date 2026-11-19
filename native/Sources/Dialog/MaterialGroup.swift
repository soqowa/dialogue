import SwiftUI

struct MaterialGroup: Identifiable {
    let id: String
    let name: String
    let files: [Material]
    let isFolder: Bool

    static func collect(_ materials: [Material]) -> [MaterialGroup] {
        var folders: [String: [Material]] = [:]
        var groups: [MaterialGroup] = []
        for material in materials {
            if let separator = material.name.firstIndex(of: "/") {
                let folder = String(material.name[..<separator])
                folders[folder, default: []].append(material)
            } else {
                groups.append(MaterialGroup(id: "file:" + material.id, name: material.name, files: [material], isFolder: false))
            }
        }
        for (name, files) in folders {
            groups.append(MaterialGroup(id: "folder:" + name, name: name, files: files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, isFolder: true))
        }
        return groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func relativeName(_ material: Material) -> String {
        isFolder ? String(material.name.dropFirst(name.count + 1)) : material.name
    }
}

struct MaterialGroupRow: View {
    @EnvironmentObject private var app: AppModel
    let group: MaterialGroup
    let compact: Bool
    @State private var expanded = false
    private let tint = Color(red: 0.54, green: 0.59, blue: 0.49)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if group.isFolder {
                Button { expanded.toggle() } label: {
                    HStack(spacing: compact ? 7 : 12) {
                        Image(systemName: expanded ? "folder.fill" : "folder")
                            .font(.system(size: compact ? 13 : 20)).foregroundStyle(tint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.name).font(.system(size: compact ? 11 : 13)).lineLimit(1)
                            if !compact { Text("Файлов: \(group.files.count)").font(.system(size: 10)).foregroundStyle(tint) }
                        }
                        Spacer(minLength: 4)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9)).foregroundStyle(tint)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, compact ? 0 : 10)
                }
                .buttonStyle(DialogButtonStyle(.row))
                .help(group.name)
                .accessibilityValue(expanded ? "Развёрнута" : "Свёрнута")
                if expanded {
                    LazyVStack(alignment: .leading, spacing: compact ? 10 : 0) {
                        ForEach(group.files) { file in fileRow(file) }
                    }
                    .padding(.leading, compact ? 20 : 28)
                    .padding(.vertical, compact ? 8 : 0)
                }
            } else if let file = group.files.first {
                fileRow(file)
            }
        }
    }

    private func fileRow(_ file: Material) -> some View {
        HStack(spacing: compact ? 7 : 13) {
            Image(systemName: "doc.text").foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 5) {
                Text(group.relativeName(file)).font(.system(size: compact ? 11 : 13)).lineLimit(compact ? 1 : 2)
                if !compact { Text("\(file.characters.formatted()) символов · \(file.chunks) фрагм.").font(.system(size: 10)).foregroundStyle(tint) }
            }
            if !compact {
                Spacer()
                DialogIconButton(symbol: "trash", label: "Удалить из базы") { let projectID = app.currentProjectID; Task { await app.deleteMaterial(file.id, projectID: projectID) } }.foregroundStyle(tint)
            }
        }
        .padding(.vertical, compact ? 3 : 14)
        .help(file.name)
    }
}

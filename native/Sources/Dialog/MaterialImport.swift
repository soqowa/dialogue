import Foundation

struct ImportItem: Sendable { let url: URL; let path: String; let size: Int }
struct ImportSelection: Sendable { var files: [ImportItem] = []; var skipped = 0; var errors: [String] = [] }

enum MaterialImport {
    private static let ignored = Set([".git", "node_modules", ".venv", "venv", ".build", "build", "dist", "target", "vendor", "coverage", ".next", ".cache", "__pycache__"])
    private static let extensions = Set("txt md mdx js jsx ts tsx mjs cjs py ipynb java c cpp h hpp cs go rs rb php swift kt kts scala sql html css scss json yaml yml toml xml sh r tex csv vue svelte pdf docx".split(separator: " ").map(String.init))
    private static let names = Set(["readme", "license", "makefile", "dockerfile", "justfile", "cmakelists.txt"])
    static func collect(_ urls: [URL]) -> ImportSelection {
        var result = ImportSelection()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        func append(_ url: URL, path: String) {
            do {
                let info = try url.resourceValues(forKeys: keys)
                guard info.isRegularFile == true, info.isSymbolicLink != true,
                      extensions.contains(url.pathExtension.lowercased()) || names.contains(url.lastPathComponent.lowercased()) else { result.skipped += 1; return }
                guard (info.fileSize ?? 0) <= 20 * 1024 * 1024 else { result.errors.append("\(path): больше 20 МБ"); return }
                result.files.append(ImportItem(url: url, path: path, size: info.fileSize ?? 0))
            } catch { result.errors.append("\(path): \(error.localizedDescription)") }
        }
        for root in urls {
            do {
                let info = try root.resourceValues(forKeys: keys)
                if info.isSymbolicLink == true { result.skipped += 1; continue }
                if info.isDirectory != true { append(root, path: root.lastPathComponent); continue }
                let base = root.resolvingSymlinksInPath().standardizedFileURL
                guard let iterator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles], errorHandler: { url, error in result.errors.append("\(url.lastPathComponent): \(error.localizedDescription)"); return true }) else { continue }
                for case let file as URL in iterator {
                    let values = try? file.resourceValues(forKeys: keys)
                    if ignored.contains(file.lastPathComponent.lowercased()) || values?.isSymbolicLink == true { iterator.skipDescendants(); result.skipped += 1; continue }
                    if values?.isDirectory == true { continue }
                    let resolved = file.resolvingSymlinksInPath().standardizedFileURL
                    guard resolved.path.hasPrefix(base.path + "/") else { result.skipped += 1; continue }
                    let relative = root.lastPathComponent + "/" + String(resolved.path.dropFirst(base.path.count + 1))
                    append(resolved, path: relative)
                }
            } catch { result.errors.append("\(root.lastPathComponent): \(error.localizedDescription)") }
        }
        result.files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return result
    }
}

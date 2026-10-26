import Foundation

/// 支持的扩展名及显示名称（与 Python 端 plan.py 保持一致）
let supportedExtensions: [String: String] = [
    "docx": "Word", "xlsx": "Excel", "pptx": "PowerPoint",
    "html": "HTML", "htm": "HTML", "pdf": "PDF", "csv": "CSV",
]

enum Planner {
    static func isSupported(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix("~$") || name.hasPrefix(".") { return false }  // Office 临时文件、隐藏文件
        return supportedExtensions[url.pathExtension.lowercased()] != nil
    }

    /// 展开文件夹。返回 (文件, 相对路径) 列表和忽略的文件数。
    static func collect(_ urls: [URL]) -> (files: [(URL, String)], skipped: Int) {
        var found: [(URL, String)] = []
        var skipped = 0
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let base = url.deletingLastPathComponent().standardizedFileURL.path
                let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                      options: [.skipsHiddenFiles, .skipsPackageDescendants])
                var batch: [(URL, String)] = []
                while let f = e?.nextObject() as? URL {
                    guard (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                    if isSupported(f) {
                        var rel = f.standardizedFileURL.path
                        if rel.hasPrefix(base + "/") { rel.removeFirst(base.count + 1) }
                        batch.append((f, rel))
                    } else {
                        skipped += 1
                    }
                }
                found += batch.sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
            } else if isSupported(url) {
                found.append((url, url.lastPathComponent))
            } else {
                skipped += 1
            }
        }
        return (found, skipped)
    }

    /// 决定每个文件的输出路径：默认与原文件同目录、同名、扩展名 .md；
    /// 同一批次中重名（如 a.docx 与 a.pdf）时，后者改为 a_pdf.md。
    static func plan(_ items: [FileItem], outDir: URL?) -> [URL] {
        var used = Set<String>()
        return items.map { item in
            var dst: URL
            if let outDir {
                dst = outDir.appendingPathComponent(item.relativePath).deletingPathExtension().appendingPathExtension("md")
            } else {
                dst = item.url.deletingPathExtension().appendingPathExtension("md")
            }
            if used.contains(dst.path.lowercased()) {
                let stem = item.url.deletingPathExtension().lastPathComponent
                dst = dst.deletingLastPathComponent()
                    .appendingPathComponent("\(stem)_\(item.url.pathExtension.lowercased()).md")
            }
            used.insert(dst.path.lowercased())
            return dst
        }
    }
}

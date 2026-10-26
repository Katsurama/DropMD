import AppKit
import Foundation
import SwiftUI

enum ItemStatus: Equatable {
    case waiting, running, ok, failed, skipped

    var label: String {
        switch self {
        case .waiting: return "等待"
        case .running: return "转换中"
        case .ok: return "成功"
        case .failed: return "失败"
        case .skipped: return "已跳过"
        }
    }

    var color: Color {
        switch self {
        case .waiting: return .secondary
        case .running: return .accentColor
        case .ok: return .green
        case .failed: return .red
        case .skipped: return .orange
        }
    }
}

struct FileItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let relativePath: String
    var status: ItemStatus = .waiting
    var info: String
    var dst: URL?

    var name: String { url.lastPathComponent }
}

enum ConvertMode: String, CaseIterable, Identifiable {
    case fast, hq
    var id: String { rawValue }
    var label: String { self == .fast ? "快速" : "高精度" }
}

enum WordEngine: String, CaseIterable, Identifiable {
    case markitdown, pandoc
    var id: String { rawValue }
    var label: String { self == .markitdown ? "MarkItDown（快速）" : "Pandoc（导出图片）" }
}

let ocrEngineNames: [String: String] = [
    "rapidocr": "RapidOCR（多语言混合）",
    "vision": "Apple Vision（实况文本）",
]

/// Apple Vision 一次只能以一种东亚语言为主，需要用户选择
struct VisionLanguage: Identifiable {
    let code: String
    let name: String
    var id: String { code }
}

let visionLanguages: [VisionLanguage] = [
    VisionLanguage(code: "zh-Hans", name: "简体中文"),
    VisionLanguage(code: "zh-Hant", name: "繁体中文"),
    VisionLanguage(code: "ja-JP", name: "日文"),
]

@MainActor
final class AppModel: ObservableObject {
    @Published var items: [FileItem] = []
    @Published var running = false
    @Published var statusText = "准备就绪"
    @Published var progress: Double = 0
    @Published var progressTotal: Double = 1
    @Published var engineStatus: Engine.Status?

    // 设置（只保存在本机的 UserDefaults 中）
    private let defaults = UserDefaults.standard
    @Published var mode: ConvertMode { didSet { defaults.set(mode.rawValue, forKey: "mode") } }
    @Published var wordEngine: WordEngine { didSet { defaults.set(wordEngine.rawValue, forKey: "wordEngine") } }
    @Published var ocrEngine: String { didSet { defaults.set(ocrEngine, forKey: "ocrEngine") } }
    @Published var visionLang: String { didSet { defaults.set(visionLang, forKey: "visionLang") } }
    @Published var formulas: Bool { didSet { defaults.set(formulas, forKey: "formulas") } }
    @Published var outputCustom: Bool { didSet { defaults.set(outputCustom, forKey: "outputCustom") } }
    @Published var customDir: URL? { didSet { defaults.set(customDir?.path, forKey: "customDir") } }

    let engine = Engine()
    private var stopRequested = false
    private var activeDownloader: ModelDownloader?

    init() {
        mode = ConvertMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .fast
        wordEngine = WordEngine(rawValue: defaults.string(forKey: "wordEngine") ?? "") ?? .markitdown
        ocrEngine = defaults.string(forKey: "ocrEngine") ?? "rapidocr"
        visionLang = defaults.string(forKey: "visionLang") ?? "zh-Hans"
        formulas = defaults.bool(forKey: "formulas")
        outputCustom = defaults.bool(forKey: "outputCustom")
        customDir = defaults.string(forKey: "customDir").map { URL(fileURLWithPath: $0) }
    }

    var pandocAvailable: Bool { engineStatus?.pandoc ?? true }
    var ocrEngines: [String] { engineStatus?.ocrEngines ?? ["rapidocr", "vision"] }

    func loadStatus() async {
        do {
            engineStatus = try await engine.status(formulas: false)
            if !ocrEngines.contains(ocrEngine) { ocrEngine = engineStatus?.defaultOcr ?? "rapidocr" }
            if !pandocAvailable { wordEngine = .markitdown }
        } catch {
            statusText = error.localizedDescription
        }
    }

    // MARK: - 文件列表

    func add(_ urls: [URL]) {
        guard !running else { return }
        let (found, skipped) = Planner.collect(urls)
        let known = Set(items.map { $0.url.standardizedFileURL.path })
        var added = 0
        for (url, rel) in found where !known.contains(url.standardizedFileURL.path) {
            items.append(FileItem(url: url, relativePath: rel,
                                  info: supportedExtensions[url.pathExtension.lowercased()] ?? ""))
            added += 1
        }
        statusText = "已添加 \(added) 个文件" + (skipped > 0 ? "，忽略了 \(skipped) 个不支持的文件" : "")
    }

    func remove(_ ids: Set<FileItem.ID>) {
        guard !running else { return }
        items.removeAll { ids.contains($0.id) }
    }

    func clear() {
        guard !running else { return }
        items.removeAll()
        progress = 0
        statusText = "准备就绪"
    }

    /// 用内置编辑器打开转换结果（尚未转换的文件则在访达中显示）
    func openInEditor(_ ids: Set<FileItem.ID>) {
        var others: [URL] = []
        for item in items where ids.contains(item.id) {
            if let dst = item.dst, FileManager.default.fileExists(atPath: dst.path) {
                NSDocumentController.shared.openDocument(withContentsOf: dst, display: true) { _, _, _ in }
            } else {
                others.append(item.url)
            }
        }
        if !others.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(others) }
    }

    func reveal(_ ids: Set<FileItem.ID>) {
        let urls = items.filter { ids.contains($0.id) }.map { item -> URL in
            if let dst = item.dst, FileManager.default.fileExists(atPath: dst.path) { return dst }
            return item.url
        }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func chooseFiles() {
        let p = NSOpenPanel()
        p.title = "选择要转换的文件"
        p.prompt = "添加"
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = true
        if p.runModal() == .OK { add(p.urls) }
    }

    func chooseFolder() {
        let p = NSOpenPanel()
        p.title = "选择文件夹（包含所有子文件夹）"
        p.prompt = "添加"
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        if p.runModal() == .OK { add(p.urls) }
    }

    func chooseOutputDir() {
        let p = NSOpenPanel()
        p.title = "选择输出文件夹"
        p.prompt = "选择"
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        if p.runModal() == .OK, let url = p.url {
            customDir = url
            outputCustom = true
        }
    }

    // MARK: - 转换

    private func alert(_ title: String, _ text: String, style: NSAlert.Style = .informational) {
        let a = NSAlert()
        a.alertStyle = style
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "好")
        a.runModal()
    }

    /// 确认并下载高精度模型。这是唯一的联网行为，必须先取得用户同意。
    func ensureModels(showWhenPresent: Bool = false) async -> Bool {
        let st: Engine.Status
        do {
            st = try await engine.status(formulas: formulas)
        } catch {
            alert("无法检查模型", error.localizedDescription, style: .warning)
            return false
        }
        if st.missing.isEmpty {
            if showWhenPresent { alert("高精度模型", "当前设置所需的模型都已下载。") }
            return true
        }
        let total = st.missing.reduce(0) { $0 + $1.sizeMb }
        let list = st.missing.map { "• \($0.title)：约 \($0.sizeMb) MB\n   来源：\($0.source)" }.joined(separator: "\n")
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = "需要下载识别模型"
        a.informativeText = """
        高精度模式需要先下载识别模型。这是 DropMD 唯一的联网行为，只下载模型文件，不会上传您的任何文件或信息。
        下载使用 macOS 系统网络（与 Safari 相同的网络和代理设置），每个文件都会校验完整性。

        \(list)

        合计约 \(total) MB（实际大小可能略有出入）
        保存位置：\(st.modelsDir)

        OCR 使用程序内置的 RapidOCR 或系统自带的 Apple Vision，不需要下载。
        是否同意下载？
        """
        a.addButton(withTitle: "同意并下载")
        a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return false }

        // 用 macOS 系统网络下载（与 Safari 相同的 DNS 与代理设置）
        let wasRunning = running
        running = true
        stopRequested = false
        defer { if !wasRunning { running = false } }
        statusText = "正在连接 huggingface.co…"
        progress = 0
        progressTotal = 1
        let downloader = ModelDownloader()
        activeDownloader = downloader
        defer { activeDownloader = nil }
        let modelsDir = URL(fileURLWithPath: st.modelsDir, isDirectory: true)
        do {
            try await downloader.download(st.missing, modelsDir: modelsDir) { done, total, label in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if total > 0 {
                            self.progressTotal = Double(total)
                            self.progress = Double(done)
                            let mb = { (b: Int64) in String(format: "%.0f", Double(b) / 1_000_000) }
                            self.statusText = "正在下载 \(label)  \(mb(done)) / \(mb(total)) MB"
                        } else {
                            self.statusText = label
                        }
                    }
                }
            }
            await Task.yield()
            statusText = "模型下载完成"
            return true
        } catch {
            await Task.yield()
            let msg = ModelDownloader.describe(error)
            statusText = "模型下载未完成"
            if !(error is CancellationError) && (error as? URLError)?.code != .cancelled {
                alert("下载未完成", "模型下载失败：\(msg)\n\n已下载完成的文件会保留，重试时不会重复下载。", style: .warning)
            }
            return false
        }
    }

    /// 对已存在的同名 .md 逐一询问。返回 nil 表示取消。
    private func resolveConflicts(_ indices: [Int]) -> [Int]? {
        var result: [Int] = []
        var policy: Bool?
        for i in indices {
            guard let dst = items[i].dst, FileManager.default.fileExists(atPath: dst.path) else {
                result.append(i)
                continue
            }
            var overwrite = policy
            if overwrite == nil {
                let a = NSAlert()
                a.alertStyle = .warning
                a.messageText = "“\(dst.lastPathComponent)”已经存在"
                a.informativeText = "位置：\(dst.deletingLastPathComponent().path)\n是否覆盖？"
                a.addButton(withTitle: "跳过")
                a.addButton(withTitle: "覆盖")
                a.addButton(withTitle: "取消转换")
                a.showsSuppressionButton = true
                a.suppressionButton?.title = "对其余同名文件执行相同操作"
                let r = a.runModal()
                if r == .alertThirdButtonReturn { return nil }
                overwrite = (r == .alertSecondButtonReturn)
                if a.suppressionButton?.state == .on { policy = overwrite }
            }
            if overwrite == true {
                result.append(i)
            } else {
                items[i].status = .skipped
                items[i].info = "同名 .md 已存在，未覆盖"
            }
        }
        return result
    }

    func start() async {
        guard !running else { return }
        guard !items.isEmpty else {
            alert("提示", "请先拖入或选择要转换的文件。")
            return
        }
        var outDir: URL?
        if outputCustom {
            guard let d = customDir else {
                alert("提示", "请先选择输出文件夹。")
                return
            }
            outDir = d
        }
        running = true
        stopRequested = false
        defer { running = false }

        let dsts = Planner.plan(items, outDir: outDir)
        for i in items.indices {
            items[i].dst = dsts[i]
            items[i].status = .waiting
            items[i].info = ""
        }

        let needsHQ = mode == .hq && items.contains { $0.url.pathExtension.lowercased() == "pdf" }
        if needsHQ, !(await ensureModels()) { return }
        if stopRequested { return }

        guard let selected = resolveConflicts(Array(items.indices)) else {
            statusText = "已取消"
            return
        }
        if selected.isEmpty {
            statusText = "没有需要转换的文件"
            return
        }

        let request: [String: Any] = [
            "jobs": selected.map { ["src": items[$0].url.path, "dst": items[$0].dst!.path] },
            "options": [
                "mode": mode.rawValue,
                "word_engine": wordEngine.rawValue,
                "ocr_engine": ocrEngine,
                "vision_lang": visionLang,
                "formulas": formulas,
            ],
        ]
        guard let input = try? JSONSerialization.data(withJSONObject: request) else { return }

        progress = 0
        progressTotal = Double(selected.count)
        statusText = "正在转换… 0 / \(selected.count)"
        do {
            try await engine.run(["convert"], input: input) { data in
                guard let ev = Engine.decodeEvent(data) else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let k = ev.index, k < selected.count else { return }
                        let i = selected[k]
                        guard i < self.items.count else { return }
                        if ev.event == "start" {
                            self.items[i].status = .running
                        } else if ev.event == "result" {
                            let ok = ev.ok ?? false
                            self.items[i].status = ok ? .ok : .failed
                            let info = ev.info ?? ""
                            self.items[i].info = ok ? "\(info) → \(self.items[i].dst?.lastPathComponent ?? "")" : info
                            self.progress = Double(k + 1)
                            self.statusText = "正在转换… \(k + 1) / \(selected.count)"
                        }
                    }
                }
            }
        } catch {
            alert("转换引擎出错", error.localizedDescription, style: .warning)
        }
        await Task.yield()
        for i in selected where items[i].status == .waiting || items[i].status == .running {
            items[i].status = .skipped
            items[i].info = stopRequested ? "已停止" : "引擎意外退出"
            if let dst = items[i].dst {
                try? FileManager.default.removeItem(at: dst.appendingPathExtension("part"))
            }
        }
        let okCount = selected.filter { items[$0].status == .ok }.count
        let failCount = selected.filter { items[$0].status == .failed }.count
        statusText = (stopRequested ? "已停止。" : "") + "完成：成功 \(okCount) 个，失败 \(failCount) 个"
        if failCount > 0 {
            alert("转换完成", "成功 \(okCount) 个，失败 \(failCount) 个。\n失败原因请查看列表中的“说明”一栏。", style: .warning)
        }
    }

    func stop() {
        stopRequested = true
        statusText = "正在停止…"
        activeDownloader?.cancel()
        engine.terminate()
    }
}

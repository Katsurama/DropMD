import AppKit
import UniformTypeIdentifiers

extension EditorController {
    // MARK: - 导出、打印与分享

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: String(localized: "好"))
        a.runModal()
    }

    private func savePanel(ext: String, type: UTType, title: String? = nil) -> URL? {
        let p = NSSavePanel()
        p.title = title ?? String(localized: "导出为 \(ext.uppercased())")
        p.prompt = String(localized: "导出")
        p.allowedContentTypes = [type]
        p.canCreateDirectories = true
        let base = fileURL?.deletingPathExtension().lastPathComponent
            ?? DocumentTitleSuggester.fallbackTitle(from: pendingText)
            ?? String(localized: "未命名")
        p.nameFieldStringValue = "\(base).\(ext)"
        if let dir = fileURL?.deletingLastPathComponent() { p.directoryURL = dir }
        return p.runModal() == .OK ? p.url : nil
    }

    private static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 导出为 Word（.docx，beta）
    func exportWord() {
        flushPendingEdits()
        let text = pendingText
        let docxType = UTType(filenameExtension: "docx") ?? .data
        guard let url = savePanel(ext: "docx", type: docxType, title: String(localized: "导出为 Word")) else { return }
        let base = fileURL?.deletingLastPathComponent()
        Task { @MainActor in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try WordExport.export(markdown: text, to: url, base: base)
                }.value
            } catch {
                self.alert(String(localized: "导出 Word 失败"), error.localizedDescription)
            }
        }
    }

    /// 导出 HTML 时提示框标题用界面语言
    private static let calloutTitles = Dictionary(uniqueKeysWithValues: MDCallout.allCases.map { ($0.rawValue, $0.title) })

    /// 用后台的预览页面（与公式共用）生成 HTML，样式与预览一致
    func exportHTML() {
        flushPendingEdits()
        let text = pendingText
        guard let url = savePanel(ext: "html", type: .html) else { return }
        let title = url.deletingPathExtension().lastPathComponent
        let baseDir = fileURL?.deletingLastPathComponent()
        Task { @MainActor in
            do {
                let rendered = try await MathRenderer.shared.exportBody(text, ui: Self.calloutTitles)
                let body = await Task.detached(priority: .userInitiated) {
                    HTMLExport.embedLocalImages(rendered, base: baseDir)
                }.value
                // 样式表直接从 App 里读：网页脚本不能读取本机样式表的内容（WebKit 的安全限制）
                let css = MathRenderer.shared.pageURL.flatMap {
                    try? String(contentsOf: $0.deletingLastPathComponent().appendingPathComponent("preview.css"), encoding: .utf8)
                } ?? ""
                let html = """
                <!doctype html>
                <html lang="\(fonts.language.tag)">
                <head>
                <meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <meta name="generator" content="DropMD">
                <title>\(Self.htmlEscape(title))</title>
                <style>
                \(css)
                </style>
                </head>
                <body>
                <article class="markdown-body">
                \(body)
                </article>
                </body>
                </html>
                """
                try Data(html.utf8).write(to: url, options: .atomic)
            } catch {
                self.alert(String(localized: "导出 HTML 失败"), error.localizedDescription)
            }
        }
    }

    private static let a4 = NSSize(width: 595.28, height: 841.89)
    private static let printMargin: CGFloat = 48

    /// 按 A4 纸宽重新排版的离屏文本视图，用于导出 PDF
    private func printableView(of storage: NSTextStorage) -> NSView {
        let width = Self.a4.width - Self.printMargin * 2
        let copy = NSTextStorage(attributedString: storage)
        let layout = RichLayoutManager()
        copy.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100), textContainer: container)
        tv.textContainerInset = .zero
        tv.isVerticallyResizable = true
        tv.drawsBackground = false
        layout.refreshAllDisplayStyles()
        layout.ensureLayout(for: container)
        tv.setFrameSize(NSSize(width: width, height: max(100, ceil(layout.usedRect(for: container).height) + 8)))
        printStorage = copy
        return tv
    }

    /// 分享这个 .md 文件：先把单页里还没写回的字写回并存盘，再弹出系统的分享面板（否则发出去的是磁盘上的旧版本）
    func share() {
        flushPendingEdits()
        guard let window = (richView ?? textView)?.window, let url = fileURL else { return }
        // 写回的文字下一轮才进到文档里，下一轮再存
        DispatchQueue.main.async { [weak self] in
            guard let doc = NSDocumentController.shared.document(for: window), let type = doc.fileType else { return }
            doc.save(to: url, ofType: type, for: .saveOperation) { error in
                if let error {
                    self?.alert(String(localized: "无法分享"), error.localizedDescription)
                    return
                }
                guard let view = window.contentView else { return }
                let top = view.safeAreaInsets.top
                let shareX: CGFloat
                if let shareView = Self.findToolbarControl(labeled: String(localized: "分享"), in: window) {
                    shareX = shareView.convert(shareView.bounds, to: view).midX
                } else {
                    shareX = view.bounds.maxX - 58
                }
                let anchor = NSRect(x: shareX, y: view.isFlipped ? top - 1 : view.bounds.maxY - top, width: 1, height: 1)
                NSSharingServicePicker(items: [url]).show(relativeTo: anchor, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
            }
        }
    }

    static func findToolbarControl(labeled targetLabel: String, in window: NSWindow) -> NSView? {
        guard let toolbar = window.toolbar else { return nil }
        func search(in view: NSView) -> NSView? {
            if view is NSControl,
               view.accessibilityLabel() == targetLabel
                || view.accessibilityTitle() == targetLabel
                || (view as? NSButton)?.title == targetLabel {
                return view
            }
            for sub in view.subviews {
                if let hit = search(in: sub) { return hit }
            }
            return nil
        }
        func inspect(_ item: NSToolbarItem) -> NSView? {
            if let group = item as? NSToolbarItemGroup {
                for sub in group.subitems {
                    if let hit = inspect(sub) { return hit }
                }
            }
            if item.label == targetLabel, let v = item.view {
                return search(in: v) ?? v
            }
            if let v = item.view, let hit = search(in: v) {
                return hit
            }
            return nil
        }
        for item in toolbar.items {
            if let hit = inspect(item) { return hit }
        }
        return nil
    }

    func exportPDF() {
        flushPendingEdits()
        // 单页、双页都按单页的排版打印（双页的右边就是单页），不管光标在哪边，结果都一样
        guard let r = richView, let storage = r.textStorage, let window = r.window else { return }
        guard let url = savePanel(ext: "pdf", type: .pdf) else { return }
        let view = printableView(of: storage)   // 确定导出后才复制一份文档，导出完就放掉
        let info = NSPrintInfo(dictionary: [.jobSavingURL: url])
        info.jobDisposition = .save
        info.paperSize = Self.a4
        info.topMargin = Self.printMargin
        info.bottomMargin = Self.printMargin
        info.leftMargin = Self.printMargin
        info.rightMargin = Self.printMargin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = true
        let done = PrintCompletion { [weak self] in
            self?.printStorage = nil
            self?.printCompletion = nil
        }
        printCompletion = done
        op.runModal(for: window, delegate: done, didRun: #selector(PrintCompletion.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }
}

/// 导出 PDF 结束（导出完或取消）时的回调：打印用的是 Objective-C 的回调方式
final class PrintCompletion: NSObject {
    let done: () -> Void
    init(_ done: @escaping () -> Void) { self.done = done }
    @objc func printOperationDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) { done() }
}

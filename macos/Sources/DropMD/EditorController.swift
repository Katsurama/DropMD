import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// 一个编辑器窗口的控制器：连接单页编辑区（RichTextView）、双页的原文编辑区（NSTextView）
/// 与预览区（WKWebView），并提供格式化、同步滚动和导出功能。
/// 光标处的段落样式与文字样式
@MainActor
final class SelectionModel: ObservableObject {
    @Published var state = SelectionState()
}

@MainActor
final class EditorController: ObservableObject {
    weak var textView: NSTextView? { didSet { textView?.textStorage?.delegate = fonts } }
    weak var richView: RichTextView? { didSet { richView?.textStorage?.delegate = fonts } }
    weak var webView: WKWebView?
    var fileURL: URL? {
        didSet {
            guard fileURL != oldValue, let path = fileURL?.path else { return }
            language = DocLanguage.forPath(path, current: language, saved: Self.savedLanguages)
            saveLanguage()
        }
    }

    // MARK: 文档语言（状态栏左下角）

    /// 用户选择的语言；手动选择按文件记住
    @Published var language = DocLanguage.auto {
        didSet {
            guard language != oldValue else { return }
            saveLanguage()
            updateLanguage()
        }
    }
    /// 实际使用的语言（“自动”时按文字判断）
    @Published private(set) var effectiveLanguage = DocLanguage.detect("")
    private let fonts = LanguageFontFixer()
    private var languageApplied = false
    private static let languagesKey = "documentLanguages"
    private static var savedLanguages: [String: String] {
        (UserDefaults.standard.dictionary(forKey: languagesKey) as? [String: String]) ?? [:]
    }

    private func saveLanguage() {
        guard let path = fileURL?.path else { return }
        // 顺便去掉已经不存在的文件的记录，记录不会越积越多
        var all = Self.savedLanguages.filter { FileManager.default.fileExists(atPath: $0.key) }
        all[path] = language == .auto ? nil : language.rawValue
        UserDefaults.standard.set(all, forKey: Self.languagesKey)
    }

    private func updateLanguage() {
        let lang = language == .auto ? DocLanguage.detect(pendingText) : language
        guard lang != fonts.language || !languageApplied else { return }
        languageApplied = true
        fonts.language = lang
        effectiveLanguage = lang
        for storage in [richView?.textStorage, textView?.textStorage].compactMap({ $0 }) {
            storage.beginEditing()
            fonts.apply(to: storage)
            storage.endEditing()
        }
        renderPreview()
    }
    /// 当前是单页（true）还是双页（false）
    var isRichMode = true

    private var rich: RichTextView? { isRichMode ? richView : nil }

    /// 由单页编辑区设置：把尚未写回的修改立即写回文档
    var flushRichEdits: (() -> Void)?

    func flushPendingEdits() { flushRichEdits?() }

    @Published var stats = ""
    /// 光标处的样式。单独放在一个对象里：光标移动时只刷新“格式”面板，不刷新整个窗口
    let selection = SelectionModel()

    private var previewReady = false
    private var pendingText = ""
    private var renderWork: DispatchWorkItem?
    private var highlightWork: DispatchWorkItem?
    private var lastScrollLine = -1

    static var previewURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("preview/preview.html")
    }

    // MARK: - 文本变化

    func textChanged(_ text: String) {
        pendingText = text
        updateStats(text)
        if language == .auto { updateLanguage() }
        // 单页时预览是隐藏的，不需要渲染
        guard !isRichMode else { return }
        renderWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.renderPreview() }
        renderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func scheduleHighlight() {
        highlightWork?.cancel()
        let delay = (textView?.string.utf16.count ?? 0) > 200_000 ? 0.4 : 0.12   // 停顿后再高亮，连续输入不卡
        let work = DispatchWorkItem { [weak self] in
            guard let tv = self?.textView, let storage = tv.textStorage else { return }
            MarkdownHighlighter.highlight(storage)
            tv.typingAttributes = MarkdownHighlighter.baseAttributes
        }
        highlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func updateStats(_ text: String) {
        var chars = 0
        var lines = 1
        for c in text.unicodeScalars {
            if c == "\n" {
                lines += 1
            } else if !c.properties.isWhitespace {
                chars += 1
            }
        }
        stats = "\(chars) 字 · \(lines) 行"
    }

    // MARK: - 预览

    func attachWebView(_ webView: WKWebView) {
        self.webView = webView
        previewReady = false
    }

    func previewDidLoad() {
        previewReady = true
        renderPreview()
    }

    private var baseHref: String {
        guard let dir = fileURL?.deletingLastPathComponent() else { return "" }
        let s = dir.absoluteString
        return s.hasSuffix("/") ? s : s + "/"
    }

    func renderPreview() {
        guard previewReady, let webView else { return }
        webView.callAsyncJavaScript("DropMD.render(t, b, l)",
                                    arguments: ["t": pendingText, "b": baseHref, "l": fonts.language.tag],
                                    in: nil, in: .page) { [weak self] _ in
            // WebKit 在主线程回调
            MainActor.assumeIsolated {
                self?.lastScrollLine = -1
                self?.syncScroll()
            }
        }
    }

    /// 编辑区滚动时，让预览滚动到对应位置
    func syncScroll() {
        guard previewReady, let tv = textView, let webView,
              let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let visible = tv.visibleRect
        let point = NSPoint(x: 0, y: visible.minY - tv.textContainerInset.height)
        let glyph = lm.glyphIndex(for: point, in: tc)
        let charIndex = lm.characterIndexForGlyph(at: glyph)
        let ns = tv.string as NSString
        let limit = min(charIndex, ns.length)
        var line = 0
        var i = 0
        while i < limit {
            let r = ns.range(of: "\n", options: [], range: NSRange(location: i, length: limit - i))
            if r.location == NSNotFound { break }
            line += 1
            i = r.location + 1
        }
        guard line != lastScrollLine else { return }
        lastScrollLine = line
        webView.callAsyncJavaScript("DropMD.scrollToLine(l)", arguments: ["l": line], in: nil, in: .page, completionHandler: nil)
    }

    // MARK: - 编辑操作（均通过 NSTextView 进行，支持撤销）

    private func replace(_ range: NSRange, with s: String, select: NSRange? = nil) {
        guard let tv = textView else { return }
        guard tv.shouldChangeText(in: range, replacementString: s) else { return }
        tv.textStorage?.replaceCharacters(in: range, with: s)
        tv.didChangeText()
        tv.setSelectedRange(select ?? NSRange(location: range.location + (s as NSString).length, length: 0))
        tv.window?.makeFirstResponder(tv)
    }

    /// 用标记包裹选中文字；若已被包裹则去掉标记
    func wrap(_ left: String, _ right: String? = nil, placeholder: String) {
        guard let tv = textView else { return }
        let right = right ?? left
        let ns = tv.string as NSString
        let sel = tv.selectedRange()
        let l = (left as NSString).length, r = (right as NSString).length
        if sel.location >= l, NSMaxRange(sel) + r <= ns.length,
           ns.substring(with: NSRange(location: sel.location - l, length: l)) == left,
           ns.substring(with: NSRange(location: NSMaxRange(sel), length: r)) == right {
            let outer = NSRange(location: sel.location - l, length: sel.length + l + r)
            replace(outer, with: ns.substring(with: sel), select: NSRange(location: outer.location, length: sel.length))
            return
        }
        let inner = sel.length > 0 ? ns.substring(with: sel) : placeholder
        replace(sel, with: left + inner + right,
                select: NSRange(location: sel.location + l, length: (inner as NSString).length))
    }

    /// 对选中的每一行切换前缀（引用、列表等）
    func toggleLinePrefix(_ prefix: String, numbered: Bool = false) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        let lineRange = ns.lineRange(for: tv.selectedRange())
        var block = ns.substring(with: lineRange)
        let hadNewline = block.hasSuffix("\n")
        if hadNewline { block.removeLast() }
        var lines = block.components(separatedBy: "\n")
        let pattern = numbered ? #"^\d+\. "# : "^" + NSRegularExpression.escapedPattern(for: prefix)
        let re = try? NSRegularExpression(pattern: pattern)
        let allHave = lines.allSatisfy { l in
            re?.firstMatch(in: l, range: NSRange(location: 0, length: (l as NSString).length)) != nil
        }
        for (i, l) in lines.enumerated() {
            let r = NSRange(location: 0, length: (l as NSString).length)
            if allHave {
                lines[i] = re?.stringByReplacingMatches(in: l, range: r, withTemplate: "") ?? l
            } else {
                // 修复：部分行已有列表标记时，先去掉旧标记，避免出现“- - 文字”“1. 1. 文字”
                let bare = prefix == "> " ? l : l.replacingOccurrences(
                    of: #"^([-*+] \[[ xX]\] |[-*+] |\d+\. )"#, with: "", options: .regularExpression)
                lines[i] = (numbered ? "\(i + 1). " : prefix) + bare
            }
        }
        let result = lines.joined(separator: "\n") + (hadNewline ? "\n" : "")
        replace(lineRange, with: result, select: NSRange(location: lineRange.location, length: (result as NSString).length))
    }

    /// 双页：设置标题级别（0 表示正文）
    private func sourceHeading(_ level: Int) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: tv.selectedRange().location, length: 0))
        var line = ns.substring(with: lineRange)
        let hadNewline = line.hasSuffix("\n")
        if hadNewline { line.removeLast() }
        let stripped = line.replacingOccurrences(of: #"^#{1,6}[ \t]*"#, with: "", options: .regularExpression)
        let result = (level > 0 ? String(repeating: "#", count: level) + " " : "") + stripped + (hadNewline ? "\n" : "")
        replace(lineRange, with: result, select: NSRange(location: lineRange.location + (result as NSString).length - (hadNewline ? 1 : 0), length: 0))
    }

    /// 在当前位置插入独立的块（前后自动补空行）
    func insertBlock(_ block: String, selectPlaceholder placeholder: String? = nil) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        let sel = tv.selectedRange()
        var prefix = ""
        if sel.location > 0 {
            let before = ns.substring(to: sel.location)
            if !before.hasSuffix("\n\n") { prefix = before.hasSuffix("\n") ? "\n" : "\n\n" }
        }
        let text = prefix + block + "\n"
        var select: NSRange?
        if let placeholder, let r = text.range(of: placeholder) {
            let loc = (String(text[..<r.lowerBound]) as NSString).length
            select = NSRange(location: sel.location + loc, length: (placeholder as NSString).length)
        }
        replace(sel, with: text, select: select)
    }

    // MARK: - 命令

    func perform(_ action: EditorAction) {
        switch action {
        case .bold: bold()
        case .italic: italic()
        case .underline: underline()
        case .strike: strikethrough()
        case .highlight: highlight()
        case .inlineCode: inlineCode()
        case .superscriptText: if let r = rich { r.toggle(.sup) } else { wrap("<sup>", "</sup>", placeholder: "上标") }
        case .subscriptText: if let r = rich { r.toggle(.sub) } else { wrap("<sub>", "</sub>", placeholder: "下标") }
        case .kbd: if let r = rich { r.toggle(.kbd) } else { wrap("<kbd>", "</kbd>", placeholder: "⌘") }
        case .lineBreak: if let r = rich { r.insertSoftBreak() } else { replaceSelection(with: "<br>\n") }
        case .body: heading(0)
        case .heading1: heading(1)
        case .heading2: heading(2)
        case .heading3: heading(3)
        case .heading4: heading(4)
        case .heading5: heading(5)
        case .heading6: heading(6)
        case .quote: quote()
        case .codeBlock: codeBlock()
        case .bullet: bulletList()
        case .numbered: numberedList()
        case .task: taskList()
        case .outdent: outdent()
        case .indent: indent()
        case .link: link()
        case .image: image()
        case .table: table()
        case .rule: horizontalRule()
        case .details: details()
        case .footnote: footnote()
        case .inlineMath: inlineMath()
        case .mathBlock: mathBlock()
        case .callout: callout(.note)
        case .date: insertDate()
        case .emoji: NSApp.orderFrontCharacterPalette(nil)
        case .exportPDF: exportPDF()
        case .exportHTML: exportHTML()
        }
        selectionChanged()
    }

    /// 单页的选区变化时更新“格式”面板
    func selectionChanged() {
        guard let r = rich else { return }
        let state = r.selectionState
        if state != selection.state { selection.state = state }
    }

    func bold() { if let r = rich { r.toggle(.bold) } else { wrap("**", placeholder: "粗体文字") } }
    func italic() { if let r = rich { r.toggle(.italic) } else { wrap("*", placeholder: "斜体文字") } }
    func underline() { if let r = rich { r.toggle(.underline) } else { wrap("<u>", "</u>", placeholder: "下划线文字") } }
    func strikethrough() { if let r = rich { r.toggle(.strike) } else { wrap("~~", placeholder: "删除线文字") } }
    func highlight() { if let r = rich { r.toggle(.highlight) } else { wrap("==", placeholder: "高亮文字") } }
    func inlineCode() { if let r = rich { r.toggleInlineCode() } else { wrap("`", placeholder: "代码") } }

    func heading(_ level: Int) {
        if let r = rich { r.setKind(level > 0 ? .heading(level) : .body) } else { sourceHeading(level) }
    }
    func quote() { if let r = rich { r.setKind(.quote, toggle: true) } else { toggleLinePrefix("> ") } }
    func bulletList() { if let r = rich { r.setKind(.bullet(r.currentKind.depth), toggle: true) } else { toggleLinePrefix("- ") } }
    func numberedList() { if let r = rich { r.setKind(.ordered(r.currentKind.depth), toggle: true) } else { toggleLinePrefix("", numbered: true) } }
    func taskList() { if let r = rich { r.setKind(.task(r.currentKind.depth, false), toggle: true) } else { toggleLinePrefix("- [ ] ") } }
    func indent() { rich?.changeDepth(1) }
    func outdent() { rich?.changeDepth(-1) }
    func horizontalRule() { if let r = rich { r.insertRule() } else { insertBlock("---") } }
    func table() { if let r = rich { r.insertTable() } else { insertBlock("| 列 1 | 列 2 | 列 3 |\n| --- | --- | --- |\n| 内容 | 内容 | 内容 |", selectPlaceholder: "列 1") } }
    func details() {
        if let r = rich {
            r.insertDetails()
        } else {
            insertBlock("<details>\n<summary>点击展开</summary>\n\n折叠的内容\n\n</details>", selectPlaceholder: "点击展开")
        }
    }

    func callout(_ type: MDCallout) {
        if let r = rich { r.insertCallout(type) } else { insertBlock("> \(type.header)\n> 内容", selectPlaceholder: "内容") }
    }

    /// 插入今天的日期（按系统语言的长格式，例如 2026年10月26日）
    func insertDate() {
        let text = Date().formatted(date: .long, time: .omitted)
        if let r = rich { r.insertText(text, replacementRange: r.selectedRange()) } else { replaceSelection(with: text) }
    }

    /// 代码块；lang 为编程语言（用于语法高亮），可以为空
    func codeBlock(_ lang: String = "") {
        if let r = rich {
            r.setKind(.code(lang), toggle: lang.isEmpty)
        } else {
            insertBlock("```\(lang)\n代码\n```", selectPlaceholder: "代码")
        }
    }

    func inlineMath() {
        guard let formula = askText("插入行内公式", info: "LaTeX 格式，例如 E=mc^2",
                                    placeholder: "E=mc^2") else { return }
        if let r = rich { r.insertLiteral("$\(formula)$") } else { replaceSelection(with: "$\(formula)$") }
    }

    func mathBlock() {
        guard let formula = askText("插入公式块", info: "LaTeX 格式",
                                    placeholder: "\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}") else { return }
        if let r = rich { r.insertMathBlock(formula) } else { insertBlock("$$\n\(formula)\n$$") }
    }

    /// 脚注：在光标处插入 [^n]，并在文末添加 [^n]: 说明
    func footnote() {
        let text = currentMarkdown
        var n = 1
        while text.contains("[^\(n)]") { n += 1 }
        guard let note = askText("插入脚注", info: "说明文字放在文档末尾。", placeholder: "脚注说明") else { return }
        if let r = rich {
            r.insertFootnote(label: "\(n)", note: note)
        } else {
            replaceSelection(with: "[^\(n)]")
            guard let tv = textView else { return }
            let end = (tv.string as NSString).length
            let suffix = (tv.string.hasSuffix("\n") ? "\n" : "\n\n") + "[^\(n)]: \(note)\n"
            replace(NSRange(location: end, length: 0), with: suffix, select: NSRange(location: end, length: 0))
        }
    }

    func link() {
        if let r = rich {
            let range = r.selectedRange()
            let existing = range.length > 0 ? r.textStorage?.attribute(DMKey.link, at: range.location, effectiveRange: nil) as? String : nil
            guard let url = askText(existing == nil ? "添加链接" : "修改链接",
                                    info: "网址或文件路径。留空则去掉链接。",
                                    placeholder: "https://", initial: existing ?? "", allowEmpty: true) else { return }
            r.setLink(url.isEmpty ? nil : url)
            return
        }
        guard let tv = textView else { return }
        let sel = tv.selectedRange()
        let ns = tv.string as NSString
        let label = sel.length > 0 ? ns.substring(with: sel) : "链接文字"
        let s = "[\(label)](https://)"
        let urlStart = sel.location + ("[\(label)](" as NSString).length
        replace(sel, with: s, select: NSRange(location: urlStart, length: ("https://" as NSString).length))
    }

    /// 插入图片：选择本机图片文件，尽量使用相对于文档的路径
    func image() {
        let p = NSOpenPanel()
        p.title = "选择图片"
        p.prompt = "插入"
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url else { return }
        var path = url.path
        if let dir = fileURL?.deletingLastPathComponent().standardizedFileURL.path,
           url.standardizedFileURL.path.hasPrefix(dir + "/") {
            path = String(url.standardizedFileURL.path.dropFirst(dir.count + 1))
        }
        let alt = url.deletingPathExtension().lastPathComponent
        if let r = rich {
            r.insertImage(path: path, alt: alt)
            return
        }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        replaceSelection(with: "![\(alt)](\(encoded))")
    }

    /// 当前文档内容（Markdown）
    private var currentMarkdown: String {
        if let r = rich, let storage = r.textStorage { return RichBridge.markdown(from: storage) }
        return textView?.string ?? pendingText
    }

    private func replaceSelection(with s: String) {
        guard let tv = textView else { return }
        replace(tv.selectedRange(), with: s)
    }

    /// 弹出输入框；取消时返回 nil
    private func askText(_ title: String, info: String, placeholder: String, initial: String = "",
                         allowEmpty: Bool = false) -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.addButton(withTitle: "好")
        a.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        a.accessoryView = field
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty && !allowEmpty { return nil }
        return value
    }

    // MARK: - 导出

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "好")
        a.runModal()
    }

    private func savePanel(ext: String, type: UTType) -> URL? {
        let p = NSSavePanel()
        p.title = "导出为 \(ext.uppercased())"
        p.prompt = "导出"
        p.allowedContentTypes = [type]
        p.canCreateDirectories = true
        let base = fileURL?.deletingPathExtension().lastPathComponent ?? "未命名"
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

    /// 单页、双页都用预览页面生成 HTML（单页时预览也在后台加载），样式与预览一致
    func exportHTML() {
        guard previewReady, let webView else {
            alert("无法导出", "预览还在加载，请稍后再试。")
            return
        }
        // 单页的修改停顿片刻才写回文档，这里直接取编辑区当前的内容
        let text = rich?.textStorage.map(RichBridge.markdown(from:)) ?? pendingText
        guard let url = savePanel(ext: "html", type: .html) else { return }
        let title = url.deletingPathExtension().lastPathComponent
        Task { @MainActor in
            do {
                let body = try await webView.callAsyncJavaScript("return DropMD.exportBody(t)", arguments: ["t": text],
                                                                 in: nil, contentWorld: .page) as? String ?? ""
                let css = try await webView.callAsyncJavaScript("return DropMD.styleText()", arguments: [:],
                                                                in: nil, contentWorld: .page) as? String ?? ""
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
                self.alert("导出 HTML 失败", error.localizedDescription)
            }
        }
    }

    /// 打印期间保留离屏排版用的文本（打印以表单方式异步进行）
    private var printStorage: NSTextStorage?

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
        layout.ensureLayout(for: container)
        tv.setFrameSize(NSSize(width: width, height: max(100, ceil(layout.usedRect(for: container).height) + 8)))
        printStorage = copy
        return tv
    }

    func exportPDF() {
        let view: NSView
        let window: NSWindow
        if let r = rich, let storage = r.textStorage, let w = r.window {
            view = printableView(of: storage)
            window = w
        } else if previewReady, let webView, let w = webView.window {
            view = webView
            window = w
        } else {
            alert("无法导出", "请先显示预览，再导出 PDF。")
            return
        }
        guard let url = savePanel(ext: "pdf", type: .pdf) else { return }
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
        let op: NSPrintOperation
        if let web = view as? WKWebView {
            op = web.printOperation(with: info)
            op.view?.frame = web.bounds
        } else {
            op = NSPrintOperation(view: view, printInfo: info)
        }
        op.showsPrintPanel = false
        op.showsProgressPanel = true
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
}

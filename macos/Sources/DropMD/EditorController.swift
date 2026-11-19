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
    weak var richView: RichTextView? {
        didSet {
            richView?.textStorage?.delegate = fonts
            // 双击单页中的公式：修改 LaTeX
            richView?.editMath = { [weak self] source in
                let block = RichBridge.isMathBlock(source)
                guard let self, let f = self.askText(String(localized: "修改公式"), info: String(localized: "LaTeX 格式"), placeholder: "",
                                                     initial: MathAttachmentCell.latex(from: source, display: block)) else { return nil }
                return block ? "$$\n\(f)\n$$" : "$\(f)$"
            }
        }
    }
    weak var webView: WKWebView?
    var fileURL: URL? {
        didSet {
            guard fileURL != oldValue, let path = fileURL?.path else { return }
            language = DocLanguage.forPath(path, current: language, saved: Self.savedLanguages)
            saveLanguage()
            watchDeletion()
        }
    }

    // MARK: 文件被别的程序删掉

    /// 改过的文件被别的程序删掉时（如 Edge 删除下载记录会删掉临时文件），马上把内容存回原处。
    /// 否则在系统下次自动保存之前关窗口、选“还原更改”，系统找不到原文件，报“无法保存”，窗口关不掉。
    private var deletionWatch: FileDeletionWatch?
    /// 开始监视时磁盘上的内容，用来判断有没有改过（系统标记“已修改”要晚一会儿，靠不住）
    private var diskText: String?

    private func watchDeletion() {
        deletionWatch = nil
        guard let url = fileURL else { return }
        diskText = (try? Data(contentsOf: url)).map(MarkdownDocument.decode)
        deletionWatch = FileDeletionWatch(url: url) { [weak self] in
            MainActor.assumeIsolated { self?.fileWentAway() }
        }
    }

    private func fileWentAway() {
        guard let url = fileURL else { return }
        let exists = FileManager.default.fileExists(atPath: url.path)
        // 系统保存时用新文件替换了旧文件，旧文件的监视随之失效：换成监视新文件
        if exists { return watchDeletion() }
        guard let doc = NSDocumentController.shared.document(for: url), let type = doc.fileType,
              FileDeletionWatch.shouldWriteBack(fileExists: exists, edited: doc.isDocumentEdited,
                                                text: pendingText, diskText: diskText) else { return }
        doc.save(to: url, ofType: type, for: .saveOperation) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchDeletion() }
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
        for storage in [richView?.textStorage, textView?.textStorage].compactMap({ $0 }) {
            storage.beginEditing()
            fonts.apply(to: storage)
            storage.endEditing()
        }
        renderPreview()
    }
    /// 当前是单页（true）还是双页（false）
    var isRichMode = true

    /// 格式命令作用在哪边：单页时是单页；双页时看光标在哪边（右边的单页编辑区也能直接改）
    private var rich: RichTextView? {
        guard let richView else { return nil }
        return isRichMode || richView.window?.firstResponder === richView ? richView : nil
    }

    /// 由单页编辑区设置：把尚未写回的修改立即写回文档
    var flushRichEdits: (() -> Void)?

    func flushPendingEdits() { flushRichEdits?() }

    @Published var stats = ""
    /// 光标处的样式。单独放在一个对象里：光标移动时只刷新“格式”面板，不刷新整个窗口
    let selection = SelectionModel()

    private var previewReady = false
    private var pendingText = ""
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
        // 单页打的字停一下才交给文档：文件恰好在这之前被删时，监视那一刻还看不出改过，这里补上
        if let url = fileURL, !FileManager.default.fileExists(atPath: url.path) { fileWentAway() }
        // 网页预览不显示，导出 HTML 时直接把当时的全文交给它，改字时不用渲染
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
        stats = String(localized: "\(chars) 字 · \(lines) 行")
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

    /// 预览页面中的界面文字（提示框标题等），随界面语言
    private static let previewText: [String: String] = Dictionary(uniqueKeysWithValues: MDCallout.allCases.map { ($0.rawValue, $0.title) })
        .merging(["blockedImage": String(localized: "网络图片未加载（隐私保护）"), "colon": String(localized: "：")]) { a, _ in a }

    func renderPreview() {
        guard previewReady, let webView else { return }
        webView.callAsyncJavaScript("DropMD.render(t, b, l, u)",
                                    arguments: ["t": pendingText, "b": baseHref, "l": fonts.language.tag, "u": Self.previewText],
                                    in: nil, in: .page) { [weak self] _ in
            // 网页预览不显示，只用来导出；渲染完不用做别的
            _ = self
        }
    }

    // MARK: - 双页：左边原文 ↔ 右边单页（两边一起滚、光标标记）

    /// 对照表：每段原文从第几行开始、在单页里从第几个字开始（单页重新排版时算好；右边改了字后用到时重算）
    private var lineMap: RichBridge.LineMap = []
    private var lineMapText: String?
    /// 这段时间内的滚动是另一边带动的，不再传回去（否则两边来回带动、抖个不停）
    private var ignoreSourceScrollUntil = Date.distantPast
    private var ignoreRichScrollUntil = Date.distantPast

    /// 右边打了字、还没写回原文：对照表里的位置已经对不上，先不动左边的标记（写回后左边更新时再标）
    var richTextEdited = false

    func richReloaded(lineMap map: RichBridge.LineMap, for text: String) {
        lineMap = map
        lineMapText = text
        richMarkdown = text
        guard !isRichMode else { return }
        lastCursorLine = -1
        syncCursor()
    }

    /// 右边单页现在显示的是哪份 Markdown（右边重排完、或右边改的字写回后）
    var richMarkdown: String?

    private func currentLineMap() -> RichBridge.LineMap {
        let text = textView?.string ?? pendingText
        // 只在右边已经显示这份内容时才重算。左边刚改了字时右边 0.3 秒后会重排、送来新对照表（richReloaded），
        // 这期间先用旧表，不为它把整篇再排一遍（1 万行约 0.3 秒，左边每按一次回车就卡一下）
        if text != lineMapText, text == richMarkdown {
            lineMap = RichBridge.attributedWithLineMap(markdown: text, baseURL: fileURL?.deletingLastPathComponent()).1
            lineMapText = text
        }
        return lineMap
    }

    /// 原文第 line 行所在的那一段，在单页里的字的范围
    private func richRange(forLine line: Int) -> (entry: Int, range: NSRange)? {
        let map = currentLineMap()
        guard let length = richView?.textStorage?.length, length > 0,
              let i = map.lastIndex(where: { $0.line <= line }) ?? (map.isEmpty ? nil : 0) else { return nil }
        let start = min(map[i].offset, length - 1)
        let end = i + 1 < map.count ? min(map[i + 1].offset, length) : length
        return (i, NSRange(location: start, length: max(1, end - start)))
    }

    /// 单页里第 offset 个字所在行的顶端（文字区坐标）
    private func richY(_ offset: Int) -> CGFloat? {
        guard let tv = richView, let lm = tv.layoutManager, let length = tv.textStorage?.length, length > 0 else { return nil }
        let glyph = lm.glyphIndexForCharacter(at: min(max(offset, 0), length - 1))
        return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + tv.textContainerOrigin.y
    }

    /// 左边原文滚动时，右边滚到对应位置
    func syncScroll() {
        guard !isRichMode, Date() >= ignoreSourceScrollUntil else { return }
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer, let rich = richView else { return }
        let visible = tv.visibleRect
        let glyph = lm.glyphIndex(for: NSPoint(x: 0, y: visible.minY - tv.textContainerInset.height), in: tc)
        let char = lm.characterIndexForGlyph(at: glyph)
        let ns = tv.string as NSString
        let line = Self.lineNumber(in: ns, at: char)
        guard line != lastScrollLine else { return }
        lastScrollLine = line
        let map = currentLineMap()
        guard let i = map.lastIndex(where: { $0.line <= line }), var y = richY(map[i].offset) else {
            ignoreRichScrollUntil = Date().addingTimeInterval(0.3)
            rich.scroll(.zero)
            return
        }
        // 在两段之间时按行数比例往下挪，滚动更顺
        if i + 1 < map.count, let next = richY(map[i + 1].offset), map[i + 1].line > map[i].line {
            y += (next - y) * CGFloat(line - map[i].line) / CGFloat(map[i + 1].line - map[i].line)
        }
        ignoreRichScrollUntil = Date().addingTimeInterval(0.3)
        rich.scroll(NSPoint(x: 0, y: max(0, y - 24)))
    }

    /// 右边单页滚动时，左边原文滚到对应位置
    func richScrolled() {
        guard !isRichMode, Date() >= ignoreRichScrollUntil, let rich = richView, let lm = rich.layoutManager,
              let tc = rich.textContainer, let length = rich.textStorage?.length, length > 0 else { return }
        let top = rich.visibleRect.minY + 24
        let glyph = lm.glyphIndex(for: NSPoint(x: 0, y: top - rich.textContainerOrigin.y), in: tc)
        let char = lm.characterIndexForGlyph(at: glyph)
        let map = currentLineMap()
        guard let i = map.lastIndex(where: { $0.offset <= char }) else { return scrollSource(toLine: 0) }
        var line = Double(map[i].line)
        if i + 1 < map.count, let y0 = richY(map[i].offset), let y1 = richY(map[i + 1].offset), y1 > y0 {
            line += Double(map[i + 1].line - map[i].line) * Double(max(0, min(1, (top - y0) / (y1 - y0))))
        }
        scrollSource(toLine: line)
    }

    /// 原文滚到第 line 行（可以是小数）
    func scrollSource(toLine line: Double) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer,
              let clip = tv.enclosingScrollView?.contentView else { return }
        let ns = tv.string as NSString
        let whole = Int(line)
        var index = 0
        for _ in 0..<whole {
            let r = ns.range(of: "\n", range: NSRange(location: index, length: ns.length - index))
            guard r.location != NSNotFound else { break }
            index = NSMaxRange(r)
        }
        guard lm.numberOfGlyphs > 0 else { return }
        lm.ensureLayout(for: tc)
        let glyph = min(lm.glyphIndexForCharacter(at: min(index, max(0, ns.length - 1))), lm.numberOfGlyphs - 1)
        var rect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        // 小数部分：按这一行的高度往下挪一点，滚动更顺
        rect.origin.y += rect.height * CGFloat(line - Double(whole))
        ignoreSourceScrollUntil = Date().addingTimeInterval(0.3)
        lastScrollLine = whole
        // 用文字区自己的坐标滚动：它在滚动区里的位置不一定从 0 开始，换算交给系统
        tv.scroll(NSPoint(x: 0, y: max(0, rect.minY + tv.textContainerInset.height - clip.contentInsets.top)))
    }

    /// 双页：在右边编辑时，左边原文里对应的那几行加上淡淡的底色；不在屏幕里时左边自动滚过去
    func syncSourceMark() {
        guard !isRichMode, !richTextEdited, let rich = richView, rich.window?.firstResponder === rich,
              let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let map = currentLineMap()
        guard let i = map.lastIndex(where: { $0.offset <= rich.selectedRange().location }) else { return clearSourceMark() }
        let ns = tv.string as NSString
        let start = Self.lineStart(map[i].line, in: ns)
        var end = i + 1 < map.count ? Self.lineStart(map[i + 1].line, in: ns) : ns.length
        while end > start, let u = Unicode.Scalar(ns.character(at: end - 1)), CharacterSet.whitespacesAndNewlines.contains(u) { end -= 1 }
        let range = NSRange(location: start, length: end - start)
        guard range != sourceMarkRange else { return }
        clearSourceMark()
        guard range.length > 0 else { return }
        lm.addTemporaryAttribute(.backgroundColor, value: RichStyle.markColor.withAlphaComponent(0.16), forCharacterRange: range)
        sourceMarkRange = range
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc).offsetBy(dx: 0, dy: tv.textContainerOrigin.y)
        guard !tv.visibleRect.insetBy(dx: 0, dy: 40).contains(rect) else { return }
        ignoreSourceScrollUntil = Date().addingTimeInterval(0.3)
        tv.scroll(NSPoint(x: 0, y: max(0, rect.minY - tv.visibleRect.height * 0.3)))
    }
    private var sourceMarkRange: NSRange?

    /// 左边原文被右边的修改整体替换了：底色跟着文字没了，重新标
    func sourceTextReplaced() {
        sourceMarkRange = nil
        syncSourceMark()
    }

    func clearSourceMark() {
        if let r = sourceMarkRange, let tv = textView, NSMaxRange(r) <= (tv.string as NSString).length {
            tv.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r)
        }
        sourceMarkRange = nil
    }

    /// 第 line 行（从 0 开始）的第一个字的位置
    static func lineStart(_ line: Int, in ns: NSString) -> Int {
        var index = 0
        for _ in 0..<line {
            let r = ns.range(of: "\n", range: NSRange(location: index, length: ns.length - index))
            guard r.location != NSNotFound else { return ns.length }
            index = NSMaxRange(r)
        }
        return index
    }

    /// 双页：在右边标出左边原文光标所在的那一段；那一段不在屏幕里时，右边自动滚过去
    func syncCursor() {
        // 只管你在左边操作的时候：右边改了字、左边跟着更新时也会走到这里，那时不能动右边（你正在右边打字）
        guard !isRichMode, let tv = textView, tv.window?.firstResponder === tv, let rich = richView else { return }
        clearSourceMark()   // 回到左边编辑了：左边不用再标
        let line = Self.lineNumber(in: tv.string as NSString, at: tv.selectedRange().location)
        rich.sourceCaretLocation = richCaretLocation(at: tv.selectedRange().location, line: line)
        guard line != lastCursorLine else { return }
        lastCursorLine = line
        guard let (_, range) = richRange(forLine: line) else { rich.sourceCursorRange = nil; return }
        rich.sourceCursorRange = range
        guard let rect = rich.markRect(), !rich.visibleRect.insetBy(dx: 0, dy: 40).contains(rect) else { return }
        // 和左边光标在窗口里差不多的高度
        let caret = tv.firstRect(forCharacterRange: tv.selectedRange(), actualRange: nil)
        let ratio = tv.window.map { w in
            let inView = tv.convert(w.convertFromScreen(caret).origin, from: nil).y - tv.visibleRect.minY
            return max(0.15, min(0.7, inView / max(1, tv.visibleRect.height)))
        } ?? 0.3
        ignoreRichScrollUntil = Date().addingTimeInterval(0.3)
        rich.scroll(NSPoint(x: 0, y: max(0, rect.minY - rich.visibleRect.height * ratio)))
    }
    private var lastCursorLine = -1

    /// 左边原文第 location 个字在右边大约对应的位置：把这一块从开头到光标的原文单独排一遍，看排出来有多少字。
    /// 原文里的 ** []() 等符号右边没有，按这样算普通文字是准的；光标在符号中间时落在最近的字旁边
    func richCaretLocation(at location: Int, line: Int) -> Int? {
        guard let tv = textView, let (entry, range) = richRange(forLine: line) else { return nil }
        let map = currentLineMap()
        guard entry < map.count else { return nil }
        let ns = tv.string as NSString
        let start = Self.lineStart(map[entry].line, in: ns)
        guard location >= start else { return range.location }
        let prefix = ns.substring(with: NSRange(location: start, length: location - start))
        var rendered = RichBridge.attributed(markdown: prefix, baseURL: nil).string
        while rendered.hasSuffix("\n") { rendered.removeLast() }
        // 光标在一行开头（前面是换行）：排出来的字后面本来就有分段
        let extra = prefix.hasSuffix("\n") && !rendered.isEmpty ? 1 : 0
        let offset = (rendered as NSString).length + extra
        return min(range.location + offset, NSMaxRange(range) - 1)
    }

    /// 第 index 个字在第几行（从 0 开始）
    static func lineNumber(in ns: NSString, at index: Int) -> Int {
        let limit = min(index, ns.length)
        var line = 0
        var i = 0
        while i < limit {
            let r = ns.range(of: "\n", options: [], range: NSRange(location: i, length: limit - i))
            if r.location == NSNotFound { break }
            line += 1
            i = r.location + 1
        }
        return line
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
        let lines = toggledPrefixLines(block.components(separatedBy: "\n"), prefix: prefix, numbered: numbered)
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
        case .superscriptText: if let r = rich { r.toggle(.sup) } else { wrap("<sup>", "</sup>", placeholder: String(localized: "上标")) }
        case .subscriptText: if let r = rich { r.toggle(.sub) } else { wrap("<sub>", "</sub>", placeholder: String(localized: "下标")) }
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

    func bold() { if let r = rich { r.toggle(.bold) } else { wrap("**", placeholder: String(localized: "粗体文字")) } }
    func italic() { if let r = rich { r.toggle(.italic) } else { wrap("*", placeholder: String(localized: "斜体文字")) } }
    func underline() { if let r = rich { r.toggle(.underline) } else { wrap("<u>", "</u>", placeholder: String(localized: "下划线文字")) } }
    func strikethrough() { if let r = rich { r.toggle(.strike) } else { wrap("~~", placeholder: String(localized: "删除线文字")) } }
    func highlight() { if let r = rich { r.toggle(.highlight) } else { wrap("==", placeholder: String(localized: "高亮文字")) } }
    func inlineCode() { if let r = rich { r.toggleInlineCode() } else { wrap("`", placeholder: String(localized: "代码")) } }

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
    func table() { if let r = rich { r.insertTable() } else { insertBlock(String(localized: "| 列 1 | 列 2 | 列 3 |\n| --- | --- | --- |\n| 内容 | 内容 | 内容 |"), selectPlaceholder: String(localized: "列 1")) } }
    func details() {
        if let r = rich {
            r.insertDetails()
        } else {
            insertBlock(String(localized: "<details>\n<summary>点击展开</summary>\n\n折叠的内容\n\n</details>"), selectPlaceholder: String(localized: "点击展开"))
        }
    }

    func callout(_ type: MDCallout) {
        if let r = rich { r.insertCallout(type) } else { insertBlock(String(localized: "> \(type.header)\n> 内容"), selectPlaceholder: String(localized: "内容")) }
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
            insertBlock(String(localized: "```\(lang)\n代码\n```"), selectPlaceholder: String(localized: "代码"))
        }
    }

    func inlineMath() {
        guard let formula = askText(String(localized: "插入行内公式"), info: String(localized: "LaTeX 格式，例如 E=mc^2"),
                                    placeholder: "E=mc^2") else { return }
        if let r = rich { r.insertInlineMath(formula) } else { replaceSelection(with: "$\(formula)$") }
    }

    func mathBlock() {
        guard let formula = askText(String(localized: "插入公式块"), info: String(localized: "LaTeX 格式"),
                                    placeholder: "\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}") else { return }
        if let r = rich { r.insertMathBlock(formula) } else { insertBlock("$$\n\(formula)\n$$") }
    }

    /// 脚注：在光标处插入 [^n]，并在文末添加 [^n]: 说明
    func footnote() {
        let text = currentMarkdown
        var n = 1
        while text.contains("[^\(n)]") { n += 1 }
        guard let note = askText(String(localized: "插入脚注"), info: String(localized: "说明文字放在文档末尾。"), placeholder: String(localized: "脚注说明")) else { return }
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
            guard let url = askText(existing == nil ? String(localized: "添加链接") : String(localized: "修改链接"),
                                    info: String(localized: "网址或文件路径。留空则去掉链接。"),
                                    placeholder: "https://", initial: existing ?? "", allowEmpty: true) else { return }
            r.setLink(url.isEmpty ? nil : url)
            return
        }
        guard let tv = textView else { return }
        let sel = tv.selectedRange()
        let ns = tv.string as NSString
        let label = sel.length > 0 ? ns.substring(with: sel) : String(localized: "链接文字")
        let s = "[\(label)](https://)"
        let urlStart = sel.location + ("[\(label)](" as NSString).length
        replace(sel, with: s, select: NSRange(location: urlStart, length: ("https://" as NSString).length))
    }

    /// 插入图片：选择本机图片文件，尽量使用相对于文档的路径
    func image() {
        let p = NSOpenPanel()
        p.title = String(localized: "选择图片")
        p.prompt = String(localized: "插入")
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
        // 和单页写法相同：只编码 % # ? 空格和不成对的括号，中文保持原样
        replaceSelection(with: "![\(alt)](\(MarkdownCodec.encodeURL(RichTextView.encodedImagePath(path))))")
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
        a.addButton(withTitle: String(localized: "好"))
        a.addButton(withTitle: String(localized: "取消"))
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
        a.addButton(withTitle: String(localized: "好"))
        a.runModal()
    }

    private func savePanel(ext: String, type: UTType) -> URL? {
        let p = NSSavePanel()
        p.title = String(localized: "导出为 \(ext.uppercased())")
        p.prompt = String(localized: "导出")
        p.allowedContentTypes = [type]
        p.canCreateDirectories = true
        let base = fileURL?.deletingPathExtension().lastPathComponent ?? String(localized: "未命名")
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
            alert(String(localized: "无法导出"), String(localized: "预览还在加载，请稍后再试。"))
            return
        }
        // 单页的修改停顿片刻才写回文档，这里直接取编辑区当前的内容
        let text = rich?.textStorage.map(RichBridge.markdown(from:)) ?? pendingText
        guard let url = savePanel(ext: "html", type: .html) else { return }
        let title = url.deletingPathExtension().lastPathComponent
        Task { @MainActor in
            do {
                let rendered = try await webView.callAsyncJavaScript("return DropMD.exportBody(t)", arguments: ["t": text],
                                                                     in: nil, contentWorld: .page) as? String ?? ""
                let body = HTMLExport.embedLocalImages(rendered, base: self.fileURL?.deletingLastPathComponent())
                // 样式表直接从 App 里读：网页脚本不能读取本机样式表的内容（WebKit 的安全限制）
                let css = Self.previewURL.flatMap {
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
                // 面板从工具栏右边（分享按钮下面）弹出。SwiftUI 窗口的坐标从上往下数，要分开算
                let top = view.safeAreaInsets.top
                let anchor = NSRect(x: view.bounds.maxX - 58, y: view.isFlipped ? top - 1 : view.bounds.maxY - top, width: 1, height: 1)
                NSSharingServicePicker(items: [url]).show(relativeTo: anchor, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
            }
        }
    }

    func exportPDF() {
        // 单页、双页都按单页的排版打印（双页的右边就是单页），不管光标在哪边，结果都一样
        guard let r = richView, let storage = r.textStorage, let window = r.window else { return }
        let view = printableView(of: storage)
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
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = true
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
}

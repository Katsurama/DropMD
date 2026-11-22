import AppKit

/// 富文本编辑区使用的自定义属性（只存在于内存中，保存时转换为 Markdown）
enum DMKey {
    static let heading = NSAttributedString.Key("dm.heading")    // Int：标题级别 1–6
    static let quote = NSAttributedString.Key("dm.quote")        // Bool：引用
    static let code = NSAttributedString.Key("dm.code")          // String：代码块（值为语言）
    static let inlineCode = NSAttributedString.Key("dm.inline")  // Bool：行内代码
    static let task = NSAttributedString.Key("dm.task")          // Int：待办 1 未完成 / 2 已完成
    static let list = NSAttributedString.Key("dm.list")          // String：列表 "bullet" / "ordered"
    static let depth = NSAttributedString.Key("dm.depth")        // Int：列表、待办的缩进层级
    static let raw = NSAttributedString.Key("dm.raw")            // Bool：编辑器不支持、原样保存的段落
    static let rule = NSAttributedString.Key("dm.rule")          // Bool：分隔线
    static let highlight = NSAttributedString.Key("dm.highlight") // Bool：==高亮==
    static let kbd = NSAttributedString.Key("dm.kbd")            // Bool：<kbd>键盘按键</kbd>
    static let summary = NSAttributedString.Key("dm.summary")    // Bool：折叠块的标题
    static let inDetails = NSAttributedString.Key("dm.details")  // Bool：折叠块中的内容
    static let detailsOpen = NSAttributedString.Key("dm.open")   // Bool：折叠块标题，文件中写的是 <details open>
    static let collapsed = NSAttributedString.Key("dm.collapsed") // Bool：折叠块标题，内容已收起（只影响显示，不保存）
    static let literal = NSAttributedString.Key("dm.literal")    // Bool：原样保存的文字（如 $公式$）
    static let start = NSAttributedString.Key("dm.start")        // Int：有序列表第一项的编号（不从 1 开始时）
    static let listCode = NSAttributedString.Key("dm.listcode")  // Bool：代码块属于上面的列表项（保存时缩进到项目下面）；true 表示前后有空行
    static let codeBlock = NSAttributedString.Key("dm.codeblock") // String：每个代码块不同，相邻的代码块才分得开
    static let codeGap = NSAttributedString.Key("dm.codegap")  // Bool：相邻代码块之间显示的空行，不保存
    static let math = NSAttributedString.Key("dm.math")          // String：公式（显示为图片）的原文，如 $E=mc^2$、$$…$$
    static let link = NSAttributedString.Key("dm.link")          // String：链接地址
    static let softBreak = NSAttributedString.Key("dm.soft")     // Bool：段落里的单个换行，显示为空格，保存时写回换行
    static let title = NSAttributedString.Key("dm.title")        // String：链接、图片的提示文字原文（含引号）
    static let linkTitle = NSAttributedString.Key("dm.linkTitle") // String：带链接的图片，链接的提示文字原文
    static let imageID = NSAttributedString.Key("dm.imageID")    // String：每张图片不同，相邻的相同图片才分得开
    static let image = NSAttributedString.Key("dm.image")        // String：图片路径
    static let alt = NSAttributedString.Key("dm.alt")            // String：图片说明文字
    static let callout = NSAttributedString.Key("dm.callout")    // String：提示框标题行的原文（如 [!TIP]），显示为“提示”等

    /// 段落类型相关的属性（切换段落样式时先全部清除）
    static let quoteBlock = NSAttributedString.Key("dm.quoteblock") // String：每段引用不同，空行隔开的两段引用（如提示框和下面的普通引用）才分得开
    static let paragraphKeys = [heading, quote, code, task, list, depth, raw, rule, summary, detailsOpen, collapsed, start, listCode, codeBlock, quoteBlock]
}

/// 单页的页边距（“显示 → 页边距”、设置）：实际控制的是文字那一栏最宽多少，两边剩下的就是页边距
enum PageMargin: String, CaseIterable, Identifiable {
    case auto, wide, standard, narrow, none
    var id: String { rawValue }

    static var current: PageMargin { PageMargin(rawValue: UserDefaults.standard.string(forKey: "pageMargin") ?? "") ?? .auto }

    var title: String {
        switch self {
        case .auto: return String(localized: "自动")
        case .wide: return String(localized: "宽")
        case .standard: return String(localized: "标准")
        case .narrow: return String(localized: "窄")
        case .none: return String(localized: "最窄")
        }
    }

    /// 编辑区这么宽时，左右各留多少。自动：窗口越大文字栏越宽，但一行不超过 900
    func margin(for width: CGFloat) -> CGFloat {
        let column: CGFloat
        switch self {
        case .auto: column = min(max(672, width * 0.62), 900)
        case .wide: column = 672
        case .standard: column = 800
        case .narrow: column = 960
        case .none: column = .greatestFiniteMagnitude
        }
        return max(32, ((width - column) / 2).rounded())   // 窗口再窄也留 32
    }
}

/// 字号（菜单“显示 → 字号”、设置）：整块编辑区按比例放大缩小，排版、页边距照常，导出和保存不受影响
enum TextScale: String, CaseIterable, Identifiable {
    case auto, large, medium, small
    var id: String { rawValue }

    static var current: TextScale { TextScale(rawValue: UserDefaults.standard.string(forKey: "textScale") ?? "") ?? .auto }

    var title: String {
        switch self {
        case .auto: return String(localized: "自动")
        case .large: return String(localized: "大")
        case .medium: return String(localized: "中")
        case .small: return String(localized: "小")
        }
    }

    /// 放大倍数。中 = 原来的大小，大 = 正文大 2 号，小 = 小 1 号。
    /// 自动：屏幕点越密（笔记本）字越小，按每英寸的点数放大，最多 1.25 倍；窗口很窄时不放大
    func scale(screen: NSScreen?, viewWidth: CGFloat) -> CGFloat {
        switch self {
        case .large: return 18 / 16
        case .medium: return 1
        case .small: return 15 / 16
        case .auto:
            guard viewWidth >= 760, let screen,
                  let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return 1 }
            let mm = CGDisplayScreenSize(id).width
            guard mm > 0 else { return 1 }
            let pointsPerInch = screen.frame.width / (mm / 25.4)
            return (min(max(pointsPerInch / 110, 1), 1.25) * 20).rounded() / 20   // 取到 0.05，避免反复微调
        }
    }

    /// 按当前设置放大编辑区所在的滚动区域（自动字号按窗口宽度判断，单页/双页切换或开关格式面板时两边字号一致、不会忽大忽小）
    @MainActor static func apply(to scroll: NSScrollView?) {
        guard let scroll else { return }
        let width = scroll.window?.frame.width ?? scroll.frame.width
        let target = current.scale(screen: scroll.window?.screen, viewWidth: width)
        guard abs(scroll.magnification - target) > 0.001 else { return }
        // 缩放后滚回原来的高度（默认按中心缩放，顶部几行和光标会被推出视野）；没有横向滚动，左边从 0 开始
        // 停在最顶上时（工具栏下面留的那段空，原点是负数）按屏幕上的距离换算，否则标题会钻到工具栏底下
        let old = scroll.magnification, origin = scroll.contentView.bounds.origin.y
        let top = origin < 0 ? origin * old / target : origin
        scroll.magnification = target
        scroll.contentView.scroll(to: NSPoint(x: -scroll.contentView.contentInsets.left, y: top))   // 双页原文左边有行号栏的内边距
        scroll.reflectScrolledClipView(scroll.contentView)
        if let doc = scroll.documentView, let clip = scroll.documentView?.superview as? NSClipView {
            // 缩放后正文和可见区域一样宽，否则页边距、折行按旧宽度算，字被切掉或右边空一条
            let width = clip.bounds.width
            if width > 0, abs(doc.frame.width - width) > 0.5 { doc.setFrameSize(NSSize(width: width, height: doc.frame.height)) }
        }
    }

    /// 窗口挪到另一块屏幕、或改了字号设置时，通知编辑区重新排版（会再调 apply）
    @MainActor static func observe(_ view: NSView) -> [NSObjectProtocol] {
        let nc = NotificationCenter.default
        let relayout: @Sendable (Notification) -> Void = { [weak view] _ in MainActor.assumeIsolated { view?.needsLayout = true } }
        var tokens = [nc.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main, using: relayout)]
        if let window = view.window {
            tokens.append(nc.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main, using: relayout))
        }
        return tokens
    }
}

/// 单击链接时怎么做（设置“通用 → 链接”）
enum LinkClickAction: String, CaseIterable, Identifiable {
    case open, confirm, command
    var id: String { rawValue }

    static var current: LinkClickAction { LinkClickAction(rawValue: UserDefaults.standard.string(forKey: "linkClickAction") ?? "") ?? .confirm }

    var title: String {
        switch self {
        case .open: return String(localized: "直接打开")
        case .confirm: return String(localized: "先确认再打开")
        case .command: return String(localized: "按住 ⌘ 点击才打开")
        }
    }
}

/// 链接指向哪里：网页用浏览器、本机 Markdown 用 DropMD、其他文件在访达中显示；找不到、打不开的要告诉用户
enum LinkTarget: Equatable {
    case web(URL)              // http、https、mailto
    case markdown(URL)         // 本机的 .md
    case file(URL)             // 本机的其他文件或文件夹
    case missing(String)       // 本机文件不存在（显示的路径）
    case unsupported(String)   // 其他写法（javascript: 等），不打开
    case anchor                // 文内跳转 #标题，不处理

    static func resolve(_ link: Any, baseURL: URL?) -> LinkTarget {
        let text = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
        if text.hasPrefix("#") { return .anchor }
        let scheme = text.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression).map { text[$0].dropLast().lowercased() }
        if scheme == nil || scheme == "file" {
            // 本机路径：去掉 #位置 和 ?参数，再把 %20 这类编码还原（不经过 URL，否则中文路径会被再编码一次）
            var path = scheme == "file" ? (URL(string: text)?.path ?? "") : String(text.split(separator: "#", omittingEmptySubsequences: false)[0])
            if scheme == nil { path = String(path.split(separator: "?", omittingEmptySubsequences: false)[0]) }
            path = path.removingPercentEncoding ?? path
            // 没保存过的文档（没有所在文件夹）里的相对路径找不到
            guard path.hasPrefix("/") || baseURL != nil else { return .missing(path) }
            let target = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: path, relativeTo: baseURL)
            guard FileManager.default.fileExists(atPath: target.path) else { return .missing(path) }
            return ["md", "markdown", "mdown"].contains(target.pathExtension.lowercased()) ? .markdown(target) : .file(target)
        }
        guard ["http", "https", "mailto"].contains(scheme ?? ""), let url = (link as? URL) ?? URL(string: text) else { return .unsupported(text) }
        return .web(url)
    }

    /// 确认窗口里显示的文字：网页显示网址，文件显示文件名
    var display: String {
        switch self {
        case .web(let u): return u.absoluteString
        case .markdown(let u), .file(let u): return u.lastPathComponent
        case .missing(let s), .unsupported(let s): return s
        case .anchor: return ""
        }
    }
}

/// 双页：右边标出左边原文光标位置的样式
enum SourceMarkStyle: String, CaseIterable, Identifiable {
    case box, bar, caret
    var id: String { rawValue }

    static var isOn: Bool { UserDefaults.standard.object(forKey: "showSourceMark") as? Bool ?? true }
    static var current: SourceMarkStyle { SourceMarkStyle(rawValue: UserDefaults.standard.string(forKey: "sourceMarkStyle") ?? "") ?? .box }

    var title: String {
        switch self {
        case .box: return String(localized: "边框")
        case .bar: return String(localized: "侧边线")
        case .caret: return String(localized: "光标")
        }
    }
}

/// 段落样式
enum RichKind: Equatable {
    case body
    case heading(Int)
    case quote
    case bullet(Int)
    case ordered(Int)
    case task(Int, Bool)
    case code(String)
    case rule
    case raw
    case summary   // 折叠块的标题

    init(_ kind: MDLineKind) {
        switch kind {
        case .body: self = .body
        case .heading(let l): self = .heading(l)
        case .quote: self = .quote
        case .bullet(let d): self = .bullet(d)
        case .ordered(let d): self = .ordered(d)
        case .task(let d, let done): self = .task(d, done)
        }
    }

    var lineKind: MDLineKind {
        switch self {
        case .heading(let l): return .heading(l)
        case .quote: return .quote
        case .bullet(let d): return .bullet(d)
        case .ordered(let d): return .ordered(d)
        case .task(let d, let done): return .task(d, done)
        default: return .body
        }
    }

    var isList: Bool {
        switch self {
        case .bullet, .ordered, .task: return true
        default: return false
        }
    }

    var depth: Int {
        switch self {
        case .bullet(let d), .ordered(let d), .task(let d, _): return d
        default: return 0
        }
    }

    var isHeading: Bool {
        if case .heading = self { return true }
        return false
    }

    /// 等宽字体的段落
    var isMonospaced: Bool {
        switch self {
        case .code, .raw: return true
        default: return false
        }
    }
}

enum RichStyle {
    static let bodySize: CGFloat = 16
    static let codeSize: CGFloat = 14
    /// 行内代码：略小于正文，行高与正文自然对齐
    static let inlineCodeSize: CGFloat = 14.5
    static let inlineCodeColor = NSColor(name: "DropMD.inlineCode") { a in
        isDark(a) ? NSColor(srgbRed: 1, green: 0.47, blue: 0.44, alpha: 1) : NSColor(srgbRed: 0.84, green: 0.25, blue: 0.25, alpha: 1)
    }
    static let headingSizes: [CGFloat] = [30, 23, 19, 17, 15.5, 14.5]
    static let indent: CGFloat = 24
    static let taskTodo = "☐"
    static let taskDone = "☑"
    static let italicObliqueness = 0.18   // 系统字体（苹方等）没有斜体，用倾斜代替
    static let detailsIndent: CGFloat = 22
    static let codePadding: CGFloat = 16   // 代码块左右的内边距

    /// 行内代码底色：轻量半透明填充
    static let codeBackground = NSColor(name: "DropMD.inlineCodeBackground") { a in
        isDark(a) ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.065)
    }
    /// 键盘按键 <kbd> 立体键帽底色与边框
    static let kbdBackground = NSColor(name: "DropMD.kbdBackground") { a in
        isDark(a) ? NSColor(white: 1, alpha: 0.11) : NSColor(white: 0.97, alpha: 1)
    }
    static let kbdBorderColor = NSColor(name: "DropMD.kbdBorder") { a in
        isDark(a) ? NSColor(white: 1, alpha: 0.24) : NSColor(white: 0, alpha: 0.18)
    }
    /// 代码块的整块底色与细边框
    static let codeBlockBackground = NSColor(name: "DropMD.codeBlock") { a in
        isDark(a) ? NSColor(white: 1, alpha: 0.055) : NSColor(srgbRed: 0.965, green: 0.968, blue: 0.975, alpha: 1)
    }
    static let codeBlockBorderColor = NSColor(name: "DropMD.codeBlockBorder") { a in
        isDark(a) ? NSColor(white: 1, alpha: 0.11) : NSColor(white: 0, alpha: 0.08)
    }

    /// 轻量语法高亮（仿 Xcode 浅色 / 深色语义配色，仅用于显示）
    static let codeKeywordColor = NSColor.systemPink
    static let codeStringColor = NSColor(name: "DropMD.codeString") { a in
        isDark(a) ? NSColor(srgbRed: 0.99, green: 0.42, blue: 0.36, alpha: 1) : NSColor(srgbRed: 0.77, green: 0.10, blue: 0.09, alpha: 1)
    }
    static let codeCommentColor = NSColor(name: "DropMD.codeComment") { a in
        isDark(a) ? NSColor(srgbRed: 0.50, green: 0.56, blue: 0.62, alpha: 1) : NSColor(srgbRed: 0.36, green: 0.42, blue: 0.47, alpha: 1)
    }
    static let codeNumberColor = NSColor.systemBlue
    static let codeTypeColor = NSColor.systemTeal

    /// 正文字体：苹方。用系统字体时，汉字由系统临时替换成苹方，
    /// 标点有的被压成半宽、有的没有，顿号后面忽宽忽窄；直接用苹方，标点宽度一致。
    /// 编辑器显示时再按文档语言换成 MiSans、冠群等（DocLanguage.swift）。
    static func textFont(ofSize size: CGFloat) -> NSFont {
        NSFont(name: "PingFangSC-Regular", size: size) ?? .systemFont(ofSize: size)
    }
    static var headerBackground: NSColor { codeBlockBackground }
    private static func isDark(_ a: NSAppearance) -> Bool {
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// 单页的底色（与双页的原文区相同，切换时颜色不跳）
    static var paperColor: NSColor { .textBackgroundColor }

    /// 分隔线、引用竖线、面板边框：深色时用白色（系统的灰色分隔线在深色下发闷）
    static let lineColor = NSColor(name: "DropMD.line") { a in
        isDark(a) ? NSColor(white: 1, alpha: 0.3) : NSColor(white: 0, alpha: 0.16)
    }

    /// 表格边框：更轻盈的发丝线
    static let tableBorderColor = NSColor(name: "DropMD.tableBorder") { a in
        isDark(a) ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.10)
    }

    /// 链接柔和下划线
    static var linkUnderlineColor: NSColor { NSColor.linkColor.withAlphaComponent(0.32) }

    /// 双页里标出另一边光标所在那一段的颜色。用靛蓝：链接、“注意”提示框、选中文字是蓝色，原文里的行内代码是粉色，避开它们
    static var markColor: NSColor { .systemIndigo }

    /// 提示框的颜色（Apple DocC / GitHub 语义色）
    static func calloutColor(_ c: MDCallout) -> NSColor {
        switch c {
        case .note: return .systemBlue
        case .tip: return .systemGreen
        case .important: return .systemPurple
        case .warning: return .systemOrange
        case .caution: return .systemRed
        }
    }

    /// 提示框 SF Symbol 图标名
    static func calloutSymbol(_ c: MDCallout) -> String {
        switch c {
        case .note: return "info.circle.fill"
        case .tip: return "lightbulb.fill"
        case .important: return "exclamationmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .caution: return "xmark.octagon.fill"
        }
    }

    /// 高亮底色：深色时降低不透明度，避免变成发闷的橄榄绿
    static let highlightBackground = NSColor(name: "DropMD.highlight") { a in
        isDark(a) ? NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 0.24) : NSColor.systemYellow.withAlphaComponent(0.35)
    }

    /// 正文颜色：使用系统语义色，兼顾浅色 / 深色及高对比度辅助功能
    static var bodyColor: NSColor { .labelColor }

    static func textColor(for kind: RichKind) -> NSColor {
        if case .heading(let l) = kind, l >= 5 { return .secondaryLabelColor }
        return bodyColor
    }

    static func baseFont(for kind: RichKind) -> NSFont {
        switch kind {
        case .heading(let level):
            let size = headingSizes[min(max(level, 1), 6) - 1]
            return setBold(textFont(ofSize: size), true)
        case .code, .raw:
            return .monospacedSystemFont(ofSize: codeSize, weight: .regular)
        case .summary:
            return setBold(textFont(ofSize: bodySize), true)
        default:
            return textFont(ofSize: bodySize)
        }
    }

    static func scaled(_ font: NSFont, _ factor: CGFloat) -> NSFont {
        NSFont(descriptor: font.fontDescriptor, size: (font.pointSize * factor).rounded()) ?? font
    }

    static func isBold(_ font: NSFont?) -> Bool {
        guard let font else { return false }
        return NSFontManager.shared.traits(of: font).contains(.boldFontMask)
    }

    static func setBold(_ font: NSFont, _ bold: Bool) -> NSFont {
        bold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
             : NSFontManager.shared.convert(font, toNotHaveTrait: .boldFontMask)
    }

    static func paragraphStyle(_ kind: RichKind, block: NSTextBlock? = nil, inDetails: Bool = false) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 6
        p.paragraphSpacing = 8
        switch kind {
        case .heading(let level):
            // 参照 Apple HIG / Pages：大标题前留出足够区隔、后紧跟所管正文
            p.paragraphSpacingBefore = level == 1 ? 28 : level == 2 ? 24 : level == 3 ? 18 : 14
            p.paragraphSpacing = level == 1 ? 10 : level == 2 ? 8 : level == 3 ? 6 : 5
        case .bullet(let d), .ordered(let d):
            // 项目符号和编号由 RichLayoutManager 画在缩进区内，不是正文的一部分
            p.firstLineHeadIndent = CGFloat(d + 1) * indent
            p.headIndent = CGFloat(d + 1) * indent
            p.paragraphSpacing = 5
        case .task(let d, _):
            p.firstLineHeadIndent = CGFloat(d) * indent
            p.headIndent = CGFloat(d + 1) * indent   // 方框和后面的空格正好占一格缩进（RichLayoutManager），折行和第一行文字对齐
            p.paragraphSpacing = 5
        case .quote:
            p.firstLineHeadIndent = 28
            p.headIndent = 28
            p.tailIndent = -16
            p.paragraphSpacing = 6
        case .code, .raw:
            // 底色块由 RichLayoutManager 画出，左右留出内边距
            p.firstLineHeadIndent = codePadding
            p.headIndent = codePadding
            p.tailIndent = -codePadding
            p.lineSpacing = 4
            p.paragraphSpacing = 0
        case .summary:
            // ▸ 由 RichLayoutManager 画在缩进区内
            p.firstLineHeadIndent = detailsIndent
            p.headIndent = detailsIndent
            p.paragraphSpacingBefore = 4
        default:
            break
        }
        if inDetails {
            p.firstLineHeadIndent += detailsIndent
            p.headIndent += detailsIndent
        }
        if let block {
            p.textBlocks = [block]
            p.paragraphSpacing = 0
            p.paragraphSpacingBefore = 0
        }
        return p
    }

    /// 段落类型对应的自定义属性
    static func marks(for kind: RichKind) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .heading(let l): return [DMKey.heading: l]
        case .quote: return [DMKey.quote: true]
        case .code(let lang): return [DMKey.code: lang]
        case .bullet(let d): return [DMKey.list: "bullet", DMKey.depth: d]
        case .ordered(let d): return [DMKey.list: "ordered", DMKey.depth: d]
        case .task(let d, let done): return [DMKey.task: done ? 2 : 1, DMKey.depth: d]
        case .raw: return [DMKey.raw: true]
        case .rule: return [DMKey.rule: true]
        case .summary: return [DMKey.summary: true]
        default: return [:]
        }
    }

    /// 一级、二级标题的字距收紧一点
    static func kern(for kind: RichKind) -> Double? {
        kind == .heading(1) ? -0.4 : kind == .heading(2) ? -0.2 : nil
    }
    static var kbdFont: NSFont { .monospacedSystemFont(ofSize: codeSize - 1, weight: .medium) }

    /// 单段文字的属性
    static func attributes(for r: MDRun, kind: RichKind) -> [NSAttributedString.Key: Any] {
        // 一定要设置颜色：不设置时 NSTextView 用黑色，暗色模式下看不清
        var a: [NSAttributedString.Key: Any] = [.foregroundColor: textColor(for: kind)]
        a[.kern] = kern(for: kind)
        var font = baseFont(for: kind)
        if r.code {
            font = .monospacedSystemFont(ofSize: inlineCodeSize, weight: .regular)
            a[DMKey.inlineCode] = true
            a[.foregroundColor] = inlineCodeColor
            a[.backgroundColor] = codeBackground
        }
        if r.kbd {
            font = kbdFont
            a[DMKey.kbd] = true
            a[.backgroundColor] = kbdBackground
        }
        if r.bold || kind.isHeading { font = setBold(font, true) }
        if r.sup || r.sub {
            font = scaled(font, 0.75)
            a[.superscript] = r.sup ? 1 : -1
        }
        a[.font] = font
        if r.italic { a[.obliqueness] = italicObliqueness }
        if r.underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if r.strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if r.highlight {
            a[DMKey.highlight] = true
            a[.backgroundColor] = highlightBackground
        }
        if r.literal {
            a[DMKey.literal] = true
            if let c = MDCallout(header: r.text) {
                a[.foregroundColor] = calloutColor(c)
                a[.font] = setBold(font, true)
            } else if r.text.hasPrefix("[^") {
                // 脚注编号：像 Word 一样显示为小号上标；文末说明行开头的“[^1]:”不作上标
                a[.foregroundColor] = NSColor.linkColor
                if !r.text.hasSuffix(":") {
                    a[.superscript] = 1
                    a[.font] = scaled(font, 0.75)
                }
            } else {
                a[.foregroundColor] = NSColor.systemPurple
            }
        }
        if let url = r.link {
            a[DMKey.link] = url
            a[DMKey.title] = r.title
            a[.foregroundColor] = NSColor.linkColor
            a[.underlineStyle] = NSUnderlineStyle.single.rawValue
            a[.underlineColor] = linkUnderlineColor
            if let u = URL(string: url) { a[.link] = u }
        }
        return a
    }

    /// 新段落的输入属性（用于空文档、回车后的新段落等）
    static func typingAttributes(for kind: RichKind) -> [NSAttributedString.Key: Any] {
        var a = attributes(for: MDRun(), kind: kind)
        a[.paragraphStyle] = paragraphStyle(kind)
        for (k, v) in marks(for: kind) { a[k] = v }
        return a
    }
}

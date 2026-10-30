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
    static let literal = NSAttributedString.Key("dm.literal")    // Bool：原样保存的文字（如 $公式$）
    static let link = NSAttributedString.Key("dm.link")          // String：链接地址
    static let image = NSAttributedString.Key("dm.image")        // String：图片路径
    static let alt = NSAttributedString.Key("dm.alt")            // String：图片说明文字
    static let callout = NSAttributedString.Key("dm.callout")    // String：提示框标题行的原文（如 [!TIP]），显示为“提示”等

    /// 段落类型相关的属性（切换段落样式时先全部清除）
    static let paragraphKeys = [heading, quote, code, task, list, depth, raw, rule, summary]
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
    static let headingSizes: [CGFloat] = [28, 23, 19, 17, 16, 15]
    static let indent: CGFloat = 24
    static let taskTodo = "☐"
    static let taskDone = "☑"
    static let italicObliqueness = 0.18   // 系统字体（苹方等）没有斜体，用倾斜代替
    static let detailsIndent: CGFloat = 22

    static var codeBackground: NSColor { NSColor.quaternaryLabelColor.withAlphaComponent(0.10) }
    /// 代码块的整块底色（参考 Notion：浅灰 / 深灰，不透明，与正文底色区分开）
    static let codeBlockBackground = NSColor(name: "DropMD.codeBlock") { a in
        isDark(a) ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.04)
    }

    /// 正文字体：苹方。用系统字体时，汉字由系统临时替换成苹方，
    /// 标点有的被压成半宽、有的没有，顿号后面忽宽忽窄；直接用苹方，标点宽度一致。
    /// 编辑器显示时再按文档语言换成 MiSans、冠群等（DocLanguage.swift）。
    static func textFont(ofSize size: CGFloat) -> NSFont {
        NSFont(name: "PingFangSC-Regular", size: size) ?? .systemFont(ofSize: size)
    }
    static var headerBackground: NSColor { NSColor.quaternaryLabelColor.withAlphaComponent(0.12) }
    private static func isDark(_ a: NSAppearance) -> Bool {
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// 单页的底色（与双页的原文区相同，切换时颜色不跳）
    static var paperColor: NSColor { .textBackgroundColor }

    /// 分隔线、表格边框、面板边框：深色时用白色（系统的灰色分隔线在深色下发闷）
    static let lineColor = NSColor(name: "DropMD.line") { a in
        isDark(a) ? NSColor(white: 1, alpha: 0.3) : NSColor(white: 0, alpha: 0.16)
    }

    /// 提示框的颜色（与 GitHub 相同的含义：蓝 注意、绿 提示、紫 重要、橙 警告、红 小心）
    static func calloutColor(_ c: MDCallout) -> NSColor {
        switch c {
        case .note: return .systemBlue
        case .tip: return .systemGreen
        case .important: return .systemPurple
        case .warning: return .systemOrange
        case .caution: return .systemRed
        }
    }

    /// 高亮底色：深色时降低不透明度，避免变成发闷的橄榄绿
    static let highlightBackground = NSColor(name: "DropMD.highlight") { a in
        isDark(a) ? NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 0.24) : NSColor.systemYellow.withAlphaComponent(0.35)
    }

    /// 正文颜色：比纯黑 / 纯白柔和一些（与系统的标签文字颜色相同的做法），深色下不刺眼
    static let bodyColor = NSColor(name: "DropMD.body") { a in
        isDark(a) ? NSColor(white: 1, alpha: 0.86) : NSColor(white: 0, alpha: 0.86)
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
        p.lineSpacing = 3
        p.paragraphSpacing = 8
        switch kind {
        case .heading(let level):
            // 参考 Notion：大标题前留白更多，层次更清楚
            p.paragraphSpacingBefore = level <= 2 ? 20 : 14
            p.paragraphSpacing = 6
        case .bullet(let d), .ordered(let d):
            // 项目符号和编号由 RichLayoutManager 画在缩进区内，不是正文的一部分
            p.firstLineHeadIndent = CGFloat(d + 1) * indent
            p.headIndent = CGFloat(d + 1) * indent
            p.paragraphSpacing = 3
        case .task(let d, _):
            p.firstLineHeadIndent = CGFloat(d) * indent
            p.headIndent = CGFloat(d) * indent + 22
            p.paragraphSpacing = 3
        case .quote:
            p.firstLineHeadIndent = 20
            p.headIndent = 20
        case .code, .raw:
            // 底色块由 RichLayoutManager 画出，左右留出内边距
            p.firstLineHeadIndent = 14
            p.headIndent = 14
            p.tailIndent = -14
            p.lineSpacing = 2
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

    /// 单段文字的属性
    static func attributes(for r: MDRun, kind: RichKind) -> [NSAttributedString.Key: Any] {
        // 一定要设置颜色：不设置时 NSTextView 用黑色，暗色模式下看不清
        var a: [NSAttributedString.Key: Any] = [.foregroundColor: RichStyle.bodyColor]
        var font = baseFont(for: kind)
        if r.code {
            font = .monospacedSystemFont(ofSize: codeSize, weight: .regular)
            a[DMKey.inlineCode] = true
            a[.backgroundColor] = codeBackground
        }
        if r.kbd {
            font = .monospacedSystemFont(ofSize: codeSize - 1, weight: .medium)
            a[DMKey.kbd] = true
            a[.backgroundColor] = codeBackground
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
            a[.foregroundColor] = NSColor.linkColor
            a[.underlineStyle] = NSUnderlineStyle.single.rawValue
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

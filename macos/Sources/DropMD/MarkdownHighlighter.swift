import AppKit

/// Markdown 源码语法高亮：直接设置 NSTextStorage 的属性（不影响撤销记录）。
enum MarkdownHighlighter {
    static let baseSize: CGFloat = 14

    static var baseFont: NSFont { .monospacedSystemFont(ofSize: baseSize, weight: .regular) }

    private static func primer(_ name: String, light: UInt32, dark: UInt32,
                               lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: "DropMD.primer.\(name)") { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            let alpha = isDark ? darkAlpha : lightAlpha
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: alpha)
        }
    }

    // 深色用 GitHub“深色高对比度”配色：和单页同一个系统深灰底并排时也看得清
    private static let foregroundColor = primer("fg", light: 0x1F2328, dark: 0xF0F3F6)
    private static let headingColor = primer("heading", light: 0x0550AE, dark: 0x91CBFF)
    private static let headingMarkerColor = primer("headingMarker", light: 0x0969DA, dark: 0x71B7FF)
    private static let mutedColor = primer("muted", light: 0x59636E, dark: 0xB7BDC8)
    private static let markerColor = primer("marker", light: 0x6E7781, dark: 0xB7BDC8)
    private static let listMarkerColor = primer("listMarker", light: 0x953800, dark: 0xFFB757)
    private static let htmlTagColor = primer("htmlTag", light: 0x116329, dark: 0x72F088)
    private static let linkColor = primer("link", light: 0x0969DA, dark: 0x71B7FF)
    private static let inlineCodeColor = primer("inlineCode", light: 0xCF222E, dark: 0xFF9492)
    private static let inlineCodeBackground = primer("inlineCodeBg", light: 0xAFB8C1, dark: 0x6E7681,
                                                     lightAlpha: 0.20, darkAlpha: 0.28)
    private static let mathColor = primer("math", light: 0x8250DF, dark: 0xDBB7FF)
    private static let fenceColor = primer("fence", light: 0x0A3069, dark: 0xADDCFF)

    static var baseAttributes: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 3
        return [.font: baseFont, .foregroundColor: foregroundColor, .paragraphStyle: p]
    }

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = [.anchorsMatchLines]) -> NSRegularExpression {
        // 模式均为常量，构造失败属于编程错误
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let heading = regex(#"^(#{1,6})[ \t].*$"#)
    private static let bold = regex(#"(\*\*|__)(?=\S)[^\n]*?\S\1"#)
    private static let italic = regex(#"(?<![*\w])\*(?=[^\s*])[^*\n]*?[^\s*]\*(?![*\w])|(?<![_\w])_(?=[^\s_])[^_\n]*?[^\s_]_(?![_\w])"#)
    private static let strike = regex(#"~~(?=\S)[^\n]*?\S~~"#)
    private static let inlineCode = regex(#"`[^`\n]+`"#)
    private static let link = regex(#"!?\[[^\]\n]*\]\([^)\n]*\)"#)
    private static let autolink = regex(#"<https?://[^>\s]+>"#)
    private static let quote = regex(#"^[ \t]{0,3}>.*$"#)
    private static let listMarker = regex(#"^[ \t]*(?:[-*+]|\d+[.)])[ \t]+(?:\[[ xX]\][ \t]+)?"#)
    private static let hr = regex(#"^[ \t]{0,3}(?:-{3,}|\*{3,}|_{3,})[ \t]*$"#)
    private static let tableRow = regex(#"^[ \t]*\|.*\|[ \t]*$"#)
    private static let mathBlock = regex(#"\$\$[\s\S]*?\$\$|\\\[[\s\S]*?\\\]"#, [])
    private static let mathInline = regex(#"(?<![\\$])\$(?=[^\s$])[^$\n]*?[^\s\\$]\$(?!\d)"#)
    private static let fence = regex(#"^[ \t]{0,3}(`{3,}|~{3,})[^\n]*\n[\s\S]*?^[ \t]{0,3}\1[ \t]*$"#)
    private static let htmlTag = regex(#"</?[A-Za-z][^>\n]*>"#)

    static func highlight(_ storage: NSTextStorage) {
        let text = storage.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        guard full.length > 0 else { return }

        let fm = NSFontManager.shared
        let boldFont = fm.convert(baseFont, toHaveTrait: .boldFontMask)
        let italicFont = fm.convert(baseFont, toHaveTrait: .italicFontMask)

        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: full)

        func each(_ re: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            re.enumerateMatches(in: text, options: [], range: full) { m, _, _ in
                if let m { body(m) }
            }
        }

        each(heading) { m in
            let level = m.range(at: 1).length
            let size = baseSize + CGFloat(max(0, 4 - level)) * 2
            storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: size, weight: .bold),
                                   .foregroundColor: headingColor], range: m.range)
            storage.addAttribute(.foregroundColor, value: headingMarkerColor, range: m.range(at: 1))
        }
        each(bold) { m in storage.addAttribute(.font, value: boldFont, range: m.range) }
        each(italic) { m in storage.addAttribute(.font, value: italicFont, range: m.range) }
        each(strike) { m in
            storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                   .foregroundColor: mutedColor], range: m.range)
        }
        each(quote) { m in storage.addAttribute(.foregroundColor, value: mutedColor, range: m.range) }
        each(listMarker) { m in storage.addAttribute(.foregroundColor, value: listMarkerColor, range: m.range) }
        each(hr) { m in storage.addAttribute(.foregroundColor, value: markerColor, range: m.range) }
        each(tableRow) { m in
            let ns = text as NSString
            var i = m.range.location
            while i < NSMaxRange(m.range) {
                if ns.character(at: i) == 0x7C { // |
                    storage.addAttribute(.foregroundColor, value: markerColor, range: NSRange(location: i, length: 1))
                }
                i += 1
            }
        }
        each(htmlTag) { m in storage.addAttribute(.foregroundColor, value: htmlTagColor, range: m.range) }
        each(link) { m in storage.addAttribute(.foregroundColor, value: linkColor, range: m.range) }
        each(autolink) { m in storage.addAttribute(.foregroundColor, value: linkColor, range: m.range) }
        each(inlineCode) { m in
            storage.addAttributes([.foregroundColor: inlineCodeColor,
                                   .backgroundColor: inlineCodeBackground], range: m.range)
        }
        each(mathInline) { m in storage.addAttribute(.foregroundColor, value: mathColor, range: m.range) }
        each(mathBlock) { m in storage.addAttribute(.foregroundColor, value: mathColor, range: m.range) }
        // 代码块最后处理：内部不应用其他格式
        each(fence) { m in
            storage.addAttributes([.font: baseFont, .foregroundColor: fenceColor,
                                   .strikethroughStyle: 0], range: m.range)
            storage.removeAttribute(.backgroundColor, range: m.range)
        }
        storage.endEditing()
    }
}

import AppKit

/// 文档语言：决定汉字用哪种字形（中、日、韩的很多汉字共用同一个编码，写法不同），类似 Word 的“语言”。
enum DocLanguage: String, CaseIterable, Identifiable {
    case auto
    case zhCN = "zh-CN", zhHK = "zh-HK", zhTW = "zh-TW", ja, ko

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动"
        case .zhCN: return "简体中文"
        case .zhHK: return "繁体中文（香港）"
        case .zhTW: return "繁体中文（台湾）"
        case .ja: return "日语"
        case .ko: return "韩语"
        }
    }

    /// 正文字体：中文用随 App 提供的 MiSans（简体 / 繁体）；日语、韩语用系统自带字体（MiSans 的日语汉字写法不对）
    var fontName: String {
        switch self {
        case .auto, .zhCN: return Self.bundled("MiSans-Regular") ?? "PingFangSC-Regular"
        case .zhHK: return Self.bundled("MiSansTC") ?? "PingFangHK-Regular"
        case .zhTW: return Self.bundled("MiSansTC") ?? "PingFangTC-Regular"
        case .ja: return "HiraginoSans-W3"
        case .ko: return "AppleSDGothicNeo-Regular"
        }
    }

    /// MiSans 在构建时下载并放进 App（tools/fetch_fonts.sh）；只用 swift run 开发时没有，退回苹方
    private static func bundled(_ name: String) -> String? {
        NSFont(name: name, size: 12) == nil ? nil : name
    }

    /// 网页的 lang 属性（预览、导出）
    var tag: String { rawValue }

    /// 文件路径变了（打开、第一次保存、改名、移动）后该用的语言：有记录用记录，没有就保留当前选择
    static func forPath(_ path: String, current: DocLanguage, saved: [String: String]) -> DocLanguage {
        saved[path].flatMap(DocLanguage.init(rawValue:)) ?? current
    }

    /// “自动”时的判断：有假名为日语，有谚文为韩语；都没有时按系统语言选简体或繁体。
    /// 不按系统语言选日语字体：中文文章用日语字体会混进别的字体，笔画粗细不一。
    static func detect(_ text: String) -> DocLanguage {
        for s in text.unicodeScalars {
            switch s.value {
            // 平假名、片假名（不含中文里也用的“・”“ー”）
            case 0x3041...0x3096, 0x30A1...0x30FA: return .ja
            case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3131...0x318E: return .ko
            default: continue
            }
        }
        let lang = Locale.preferredLanguages.first ?? ""
        if lang.hasPrefix("zh-HK") || lang.hasPrefix("zh-Hant-HK") || lang.hasPrefix("zh-MO") || lang.hasPrefix("zh-Hant-MO") {
            return .zhHK
        }
        if lang.hasPrefix("zh-Hant") || lang.hasPrefix("zh-TW") { return .zhTW }
        return .zhCN
    }

    /// 中日韩字体：正文字体，以及系统为缺字的等宽字体临时换上的后备字体（换语言时也要换掉）
    private static func isCJK(_ family: String) -> Bool {
        family.contains("PingFang") || family.contains("MiSans") || family.contains("Hiragino") || family.contains("Apple SD Gothic")
    }

    /// 换成本语言的字形：中日韩字体换成本语言的字体；等宽等其他字体保留，缺字（汉字）时改用本语言的字体
    func adapt(_ font: NSFont) -> NSFont {
        guard let family = font.familyName, let target = NSFont(name: fontName, size: font.pointSize) else { return font }
        if Self.isCJK(family) {
            guard family != target.familyName else { return font }
            let bold = font.fontDescriptor.symbolicTraits.contains(.bold)
            return bold ? NSFontManager.shared.convert(target, toHaveTrait: .boldFontMask) : target
        }
        let cascade = font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor]
        if cascade?.first?.postscriptName == fontName { return font }
        let d = font.fontDescriptor.addingAttributes([.cascadeList: [target.fontDescriptor]])
        return NSFont(descriptor: d, size: font.pointSize) ?? font
    }
}

/// 文字有改动时，把改动处的字体换成文档语言的字体（单页和双页的原文共用）
final class LanguageFontFixer: NSObject, NSTextStorageDelegate {
    var language = DocLanguage.zhCN { didSet { adapted.removeAll() } }
    /// 换过的字体：双页原文每次停顿都整篇重新高亮，不必每次都重新造字体
    private var adapted: [NSFont: NSFont] = [:]

    func textStorage(_ storage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        apply(to: storage, range: editedRange)
    }

    func apply(to storage: NSTextStorage, range: NSRange? = nil) {
        let range = range ?? NSRange(location: 0, length: storage.length)
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        storage.enumerateAttribute(.font, in: range) { value, sub, _ in
            guard let font = value as? NSFont else { return }
            let new = adapted[font] ?? language.adapt(font)
            adapted[font] = new
            if new != font { storage.addAttribute(.font, value: new, range: sub) }
        }
    }
}

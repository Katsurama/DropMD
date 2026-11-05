import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Markdown 文本（.md / .markdown），在 Info.plist 中声明
    static let markdownText = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}

/// Markdown 文档。读取时自动识别 UTF-8 / UTF-16 / GB18030 / Shift-JIS 等编码；保存时用回原来的编码，
/// 编码判断错了（显示成乱码）时，只要没改内容，文件也不会变。原编码写不下新打的字时才存成 UTF-8。
struct MarkdownDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.markdownText, .plainText] }
    static var writableContentTypes: [UTType] { [.markdownText] }

    var text: String
    private var encoding: String.Encoding = .utf8
    private var bom = Data()   // 文件开头的 BOM，文字里不带，保存时写回

    init(text: String = "") {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try self.init(data: data)
    }

    /// 识别不出编码时不打开：打开就是乱码，一保存原内容就没了
    init(data: Data) throws {
        guard let found = Self.detect(data) else {
            throw CocoaError(.fileReadUnknownStringEncoding, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "无法识别这个文件的文字编码，所以没有打开。文件没有任何改动。"),
            ])
        }
        (text, encoding, bom) = found
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data())
    }

    func data() -> Data {
        text.data(using: encoding).map { bom + $0 } ?? Data(text.utf8)
    }

    /// 快速查看用：只是看一眼，识别不出也尽量显示
    static func decode(_ data: Data) -> String {
        detect(data)?.text ?? String(decoding: data, as: UTF8.self)
    }

    /// 绝大部分是正常的 UTF-8，只坏了几个字节：系统会猜成别的编码，整篇都成乱码，改了再存就真坏了
    private static func looksLikeDamagedUTF8(_ data: Data) -> Bool {
        let b = [UInt8](data)
        var valid = 0, invalid = 0, i = 0
        while i < b.count {
            let n = b[i] < 0x80 ? 0 : b[i] >= 0xC2 && b[i] <= 0xDF ? 1 : b[i] >= 0xE0 && b[i] <= 0xEF ? 2 : b[i] >= 0xF0 && b[i] <= 0xF4 ? 3 : -1
            if n == 0 { i += 1; continue }
            if n > 0, i + n < b.count, b[(i + 1)...(i + n)].allSatisfy({ $0 & 0xC0 == 0x80 }) {
                valid += 1
                i += n + 1
            } else {
                invalid += 1
                i += 1
            }
        }
        return valid > 0 && valid >= invalid * 4
    }

    /// 没有 BOM 的 UTF-16：英文和符号的另一半字节是 0，而且 0 只出现在单数位（小端）或双数位（大端）
    private static func utf16WithoutBOM(_ data: Data) -> String.Encoding? {
        guard data.count >= 2, data.count % 2 == 0 else { return nil }
        let zeros = data.enumerated().filter { $0.element == 0 }.map { $0.offset % 2 }
        guard zeros.count * 8 >= data.count else { return nil }
        if zeros.allSatisfy({ $0 == 1 }) { return .utf16LittleEndian }
        if zeros.allSatisfy({ $0 == 0 }) { return .utf16BigEndian }
        return nil
    }

    private static func detect(_ data: Data) -> (text: String, encoding: String.Encoding, bom: Data)? {
        for (mark, encoding) in [([0xEF, 0xBB, 0xBF], String.Encoding.utf8), ([0xFF, 0xFE], .utf16LittleEndian), ([0xFE, 0xFF], .utf16BigEndian)] as [([UInt8], String.Encoding)] {
            if data.starts(with: mark), let s = String(data: Data(data.dropFirst(mark.count)), encoding: encoding) {
                return (s, encoding, Data(mark))
            }
        }
        if let s = String(data: data, encoding: .utf8) { return (s, .utf8, Data()) }
        if looksLikeDamagedUTF8(data) { return nil }
        if let encoding = utf16WithoutBOM(data), let s = String(data: data, encoding: encoding) { return (s, encoding, Data()) }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        var converted: NSString?
        let found = NSString.stringEncoding(
            for: data,
            encodingOptions: [
                .suggestedEncodingsKey: [String.Encoding.utf16.rawValue, gb18030.rawValue,
                                         String.Encoding.shiftJIS.rawValue, String.Encoding.japaneseEUC.rawValue],
                .allowLossyKey: false,
            ],
            convertedString: &converted,
            usedLossyConversion: nil
        )
        guard found != 0, let s = converted as String? else { return nil }
        return (s, String.Encoding(rawValue: found), Data())
    }
}

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
        guard let found = Self.detect(data) else { throw CocoaError(.fileReadUnknownStringEncoding) }
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

    private static func detect(_ data: Data) -> (text: String, encoding: String.Encoding, bom: Data)? {
        for (mark, encoding) in [([0xEF, 0xBB, 0xBF], String.Encoding.utf8), ([0xFF, 0xFE], .utf16LittleEndian), ([0xFE, 0xFF], .utf16BigEndian)] as [([UInt8], String.Encoding)] {
            if data.starts(with: mark), let s = String(data: Data(data.dropFirst(mark.count)), encoding: encoding) {
                return (s, encoding, Data(mark))
            }
        }
        if let s = String(data: data, encoding: .utf8) { return (s, .utf8, Data()) }
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

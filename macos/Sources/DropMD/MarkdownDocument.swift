import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Markdown 文本（.md / .markdown），在 Info.plist 中声明
    static let markdownText = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}

/// Markdown 文档。保存时始终使用 UTF-8；读取时自动识别 UTF-8 / UTF-16 / GB18030 / Shift-JIS 等编码。
struct MarkdownDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.markdownText, .plainText] }
    static var writableContentTypes: [UTType] { [.markdownText] }

    var text: String

    init(text: String = "") {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = MarkdownDocument.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }

    static func decode(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        var converted: NSString?
        _ = NSString.stringEncoding(
            for: data,
            encodingOptions: [
                .suggestedEncodingsKey: [String.Encoding.utf16.rawValue, gb18030.rawValue,
                                         String.Encoding.shiftJIS.rawValue, String.Encoding.japaneseEUC.rawValue],
                .allowLossyKey: false,
            ],
            convertedString: &converted,
            usedLossyConversion: nil
        )
        return (converted as String?) ?? String(decoding: data, as: UTF8.self)
    }
}

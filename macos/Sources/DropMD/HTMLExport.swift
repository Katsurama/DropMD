import Foundation
import UniformTypeIdentifiers

enum HTMLExport {
    /// 把正文里引用的本机图片直接嵌进 HTML（data:）：导出的文件放到哪个文件夹都能显示，也不会写进本机路径。
    /// base 是文档所在的文件夹；网络图片和读不到的图片保持原样
    static func embedLocalImages(_ html: String, base: URL?) -> String {
        let pattern = try! NSRegularExpression(pattern: #"<img\b[^>]*?\ssrc="([^"]*)""#)   // src 不一定写在最前（<img width="200" src="…">）
        var out = html
        let base = base.map { URL(fileURLWithPath: $0.path, isDirectory: true) }   // 文件夹地址要以 / 结尾，相对路径才对
        for m in pattern.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            guard let r = Range(m.range(at: 1), in: out) else { continue }
            let src = out[r].replacingOccurrences(of: "&amp;", with: "&")
            let lower = src.lowercased()
            if lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("//") || lower.hasPrefix("data:") { continue }
            guard let url = URL(string: src, relativeTo: base), url.isFileURL,
                  let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType, mime.hasPrefix("image/"),
                  let data = try? Data(contentsOf: url) else { continue }
            out.replaceSubrange(r, with: "data:\(mime);base64,\(data.base64EncodedString())")
        }
        return out
    }
}

import Foundation
import ImageIO
import UniformTypeIdentifiers

enum HTMLExport {
    private static let maxEmbedBytes = 50 * 1024 * 1024

    /// 整个标签（属性值里的 < > 不算标签边界）或注释：按顺序扫，属性值、注释里写的 <img …> 不会被当成图片
    private static let tagPattern = try! NSRegularExpression(
        pattern: #"<!--[\s\S]*?-->|<(?:[^>"']|"[^"]*"|'[^']*')*>"#)
    private static let attributePattern = try! NSRegularExpression(
        pattern: #"\s([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#)

    /// 每个真正的 <img> 标签：标签开头的位置和 src 值的位置（UTF-16）
    private static func images(in html: String) -> [(tag: Int, src: NSRange)] {
        let ns = html as NSString
        var out: [(Int, NSRange)] = []
        for t in tagPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            var tag = ns.substring(with: t.range)
            if tag.hasSuffix("/>") { tag = String(tag.dropLast(2)) + " >" }   // <img src=a.png/>：/ 不算地址的一部分（长度不变）
            guard tag.count > 4, tag.prefix(4).lowercased() == "<img", tag.dropFirst(4).first.map({ $0.isWhitespace || $0 == "/" || $0 == ">" }) == true else { continue }
            for a in attributePattern.matches(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) {
                guard (tag as NSString).substring(with: a.range(at: 1)).lowercased() == "src" else { continue }
                guard let v = [2, 3, 4].map({ a.range(at: $0) }).first(where: { $0.location != NSNotFound }) else { break }
                out.append((t.range.location, NSRange(location: t.range.location + v.location, length: v.length)))
                break
            }
        }
        return out
    }

    /// src 指向的本机图片；在线图片、已嵌入的图片和其他文件返回 nil
    private static func localImage(_ rawSrc: Substring, base: URL?) -> (url: URL, mime: String)? {
        let src = rawSrc.replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty else { return nil }
        let lower = src.lowercased()
        if lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("//") || lower.hasPrefix("data:") { return nil }
        let baseDir = base.map { URL(fileURLWithPath: $0.path, isDirectory: true) }   // 文件夹地址要以 / 结尾，相对路径才对
            ?? (src.hasPrefix("/") ? URL(fileURLWithPath: "/", isDirectory: true) : nil)   // 未保存的文档：插入的图片是绝对路径
        guard let baseDir else { return nil }
        let candidate = URL(string: src, relativeTo: baseDir)
            ?? URL(fileURLWithPath: src.removingPercentEncoding ?? src, relativeTo: baseDir)
        let url = candidate.standardizedFileURL
        guard url.isFileURL,
              let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType, mime.hasPrefix("image/") else { return nil }
        return (url, mime)
    }

    /// 把正文里引用的本机图片直接嵌进 HTML（data:）：导出的文件放到哪个文件夹都能显示，也不会写进本机路径。
    /// base 是文档所在的文件夹；在线图片、超大图片（> 50 MB）和读不到的图片保持原样
    static func embedLocalImages(_ html: String, base: URL?) -> String {
        let out = NSMutableString(string: html)
        for m in images(in: html).reversed() {
            guard let image = localImage(Substring(out.substring(with: m.src)), base: base),
                  let size = regularFileSize(image.url), size <= maxEmbedBytes,
                  let data = try? Data(contentsOf: image.url) else { continue }
            out.replaceCharacters(in: m.src, with: "data:\(image.mime);base64,\(data.base64EncodedString())")
        }
        return out as String
    }

    /// 普通文件的大小；文件夹、管道等特殊文件返回 nil（读它们会卡住）
    private static func regularFileSize(_ url: URL) -> Int? {
        let v = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])   // 替身指向的文件
        return v?.isRegularFile == true ? v?.fileSize : nil
    }

    /// 快速查看：图片不嵌进页面（几十张大图转成文字会占用很多内存），换成 scheme:/第几张，网页滚到附近时才来要。
    /// 返回新的 HTML 和这些图片的位置：只有文档里写到的图片才会被读取。
    /// version：页面接着显示别的文档时地址带上它（scheme:/版本/第几张），不会拿到上一篇缓存的图片
    static func linkLocalImages(_ html: String, base: URL?, scheme: String, version: Int? = nil) -> (html: String, images: [URL]) {
        let out = NSMutableString(string: html)
        let found = images(in: html)
        var local: [Int: URL] = [:]   // 第几个 <img> → 本机图片
        for (i, m) in found.enumerated() {
            if let image = localImage(Substring(out.substring(with: m.src)), base: base) { local[i] = image.url }
        }
        var images: [URL] = []
        var index: [Int: Int] = [:]
        for i in found.indices.reversed() where local[i] != nil {
            index[i] = images.count
            images.append(local[i]!)
        }
        // 从后往前改，前面的位置不受影响
        for (i, m) in found.enumerated().reversed() {
            if let n = index[i] {
                out.replaceCharacters(in: m.src, with: "\(scheme):/" + (version.map { "\($0)/" } ?? "") + "\(n)")
            }
            out.replaceCharacters(in: NSRange(location: m.tag, length: 4), with: "<img loading=\"lazy\" decoding=\"async\"")
        }
        return (out as String, images)
    }

    /// 快速查看显示用的图片：超过 512 KB 的缩到 maxPixel 边长，小图和解不开的图（如 SVG）原样
    static func previewImage(_ url: URL, maxPixel: Int) -> (mime: String, data: Data)? {
        if let small = shrunk(url, maxPixel) { return small }
        // 缩不了的图（如 SVG）原样给：太大的不读，快速查看插件内存很少
        guard let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType, mime.hasPrefix("image/"),
              let size = regularFileSize(url), size <= 20 << 20,
              let data = try? Data(contentsOf: url) else { return nil }
        return (mime, data)
    }

    private static func shrunk(_ url: URL, _ maxPixel: Int) -> (mime: String, data: Data)? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 512 * 1024,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,   // 照片的旋转方向
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                  kCGImageSourceShouldCacheImmediately: false,
              ] as CFDictionary) else { return nil }
        let opaque = image.alphaInfo == .none || image.alphaInfo == .noneSkipFirst || image.alphaInfo == .noneSkipLast
        let type = opaque ? UTType.jpeg : UTType.png   // 透明图不能存成 JPEG
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest), let mime = type.preferredMIMEType else { return nil }
        return (mime, data as Data)
    }
}

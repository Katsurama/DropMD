import Foundation
import ImageIO
import UniformTypeIdentifiers

enum HTMLExport {
    private static let maxEmbedBytes = 50 * 1024 * 1024

    private static let imagePattern = try! NSRegularExpression(
        pattern: #"<img\b[^>]*?\ssrc=(?:"([^"]*)"|'([^']*)')"#,
        options: .caseInsensitive
    )

    private static func srcRange(in match: NSTextCheckingResult, text: String) -> Range<String.Index>? {
        for idx in [1, 2] {
            let r = match.range(at: idx)
            if r.location != NSNotFound, let sr = Range(r, in: text) { return sr }
        }
        return nil
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
        var out = html
        for m in imagePattern.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            guard let r = srcRange(in: m, text: out), let image = localImage(out[r], base: base) else { continue }
            let size = (try? image.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            if let size, size > maxEmbedBytes { continue }
            guard let data = try? Data(contentsOf: image.url), data.count <= maxEmbedBytes else { continue }
            out.replaceSubrange(r, with: "data:\(image.mime);base64,\(data.base64EncodedString())")
        }
        return out
    }

    /// 快速查看：图片不嵌进页面（几十张大图转成文字会占用很多内存），换成 scheme:/第几张，网页滚到附近时才来要。
    /// 返回新的 HTML 和这些图片的位置：只有文档里写到的图片才会被读取。
    /// version：页面接着显示别的文档时地址带上它（scheme:/版本/第几张），不会拿到上一篇缓存的图片
    static func linkLocalImages(_ html: String, base: URL?, scheme: String, version: Int? = nil) -> (html: String, images: [URL]) {
        var out = html
        var images: [URL] = []
        let matches = imagePattern.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for m in matches.reversed() {
            guard let r = srcRange(in: m, text: out), let image = localImage(out[r], base: base) else { continue }
            out.replaceSubrange(r, with: "\(scheme):/" + (version.map { "\($0)/" } ?? "") + "\(images.count)")
            images.append(image.url)
        }
        let tagged = out.replacingOccurrences(of: #"(?i)<img\s+"#, with: "<img loading=\"lazy\" decoding=\"async\" ", options: .regularExpression)
        return (tagged, images)
    }

    /// 快速查看显示用的图片：超过 512 KB 的缩到 maxPixel 边长，小图和解不开的图（如 SVG）原样
    static func previewImage(_ url: URL, maxPixel: Int) -> (mime: String, data: Data)? {
        if let small = shrunk(url, maxPixel) { return small }
        guard let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType, mime.hasPrefix("image/"),
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

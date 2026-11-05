import Foundation
import ImageIO
import UniformTypeIdentifiers

enum HTMLExport {
    private static let imagePattern = try! NSRegularExpression(pattern: #"<img\b[^>]*?\ssrc="([^"]*)""#)   // src 不一定写在最前（<img width="200" src="…">）

    /// src 指向的本机图片；网络图片、已嵌入的图片和其他文件返回 nil
    private static func localImage(_ rawSrc: Substring, base: URL?) -> (url: URL, mime: String)? {
        let src = rawSrc.replacingOccurrences(of: "&amp;", with: "&")
        let lower = src.lowercased()
        if lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("//") || lower.hasPrefix("data:") { return nil }
        let base = base.map { URL(fileURLWithPath: $0.path, isDirectory: true) }   // 文件夹地址要以 / 结尾，相对路径才对
        guard let url = URL(string: src, relativeTo: base), url.isFileURL,
              let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType, mime.hasPrefix("image/") else { return nil }
        return (url, mime)
    }

    /// 把正文里引用的本机图片直接嵌进 HTML（data:）：导出的文件放到哪个文件夹都能显示，也不会写进本机路径。
    /// base 是文档所在的文件夹；网络图片和读不到的图片保持原样
    static func embedLocalImages(_ html: String, base: URL?) -> String {
        var out = html
        for m in imagePattern.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            guard let r = Range(m.range(at: 1), in: out), let image = localImage(out[r], base: base),
                  let data = try? Data(contentsOf: image.url) else { continue }
            out.replaceSubrange(r, with: "data:\(image.mime);base64,\(data.base64EncodedString())")
        }
        return out
    }

    /// 快速查看：图片不嵌进页面（几十张大图转成文字会占用很多内存），换成 scheme:/第几张，网页滚到附近时才来要。
    /// 返回新的 HTML 和这些图片的位置：只有文档里写到的图片才会被读取
    static func linkLocalImages(_ html: String, base: URL?, scheme: String) -> (html: String, images: [URL]) {
        var out = html
        var images: [URL] = []
        let matches = imagePattern.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for m in matches.reversed() {
            guard let r = Range(m.range(at: 1), in: out), let image = localImage(out[r], base: base) else { continue }
            out.replaceSubrange(r, with: "\(scheme):/\(images.count)")
            images.append(image.url)
        }
        return (out.replacingOccurrences(of: "<img ", with: "<img loading=\"lazy\" decoding=\"async\" "), images)
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

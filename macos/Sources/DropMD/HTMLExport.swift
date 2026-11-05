import Foundation
import ImageIO
import UniformTypeIdentifiers

enum HTMLExport {
    /// 把正文里引用的本机图片直接嵌进 HTML（data:）：导出的文件放到哪个文件夹都能显示，也不会写进本机路径。
    /// base 是文档所在的文件夹；网络图片和读不到的图片保持原样。
    /// maxPixel：只是看一眼时（快速查看）把大图缩到这个边长再嵌入，免得整张读进内存；导出时不传，保持原图
    static func embedLocalImages(_ html: String, base: URL?, maxPixel: Int? = nil) -> String {
        let pattern = try! NSRegularExpression(pattern: #"<img\b[^>]*?\ssrc="([^"]*)""#)   // src 不一定写在最前（<img width="200" src="…">）
        var out = html
        let base = base.map { URL(fileURLWithPath: $0.path, isDirectory: true) }   // 文件夹地址要以 / 结尾，相对路径才对
        for m in pattern.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            guard let r = Range(m.range(at: 1), in: out) else { continue }
            let src = out[r].replacingOccurrences(of: "&amp;", with: "&")
            let lower = src.lowercased()
            if lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("//") || lower.hasPrefix("data:") { continue }
            guard let url = URL(string: src, relativeTo: base), url.isFileURL,
                  let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType, mime.hasPrefix("image/") else { continue }
            if let maxPixel, let small = shrunk(url, maxPixel) {
                out.replaceSubrange(r, with: "data:\(small.mime);base64,\(small.data.base64EncodedString())")
                continue
            }
            guard let data = try? Data(contentsOf: url) else { continue }
            out.replaceSubrange(r, with: "data:\(mime);base64,\(data.base64EncodedString())")
        }
        return out
    }

    /// 超过 512 KB 的图片缩小后的数据；小图和解不开的图（如 SVG）返回 nil，照原样嵌入
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

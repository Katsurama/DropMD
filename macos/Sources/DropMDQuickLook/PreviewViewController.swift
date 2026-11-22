import AppKit
import Quartz
import WebKit

/// 访达里按空格（Quick Look）预览 Markdown：用 App 的预览页面（与双页预览相同）显示排版后的效果。
/// 只读文件、不联网：页面的内容安全策略禁止网络请求，点击链接也不跳转。
@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController, WKNavigationDelegate {
    private var webView: WKWebView!
    /// 预览页面只加载一次，之后换文件只换内容；正在加载时来的文件排队等
    private var ready = false
    private var loading = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// 第几次预览：等待中又来了新文件时，旧的那次不再往下做
    private var revision = 0
    private let images = LocalImageHandler()

    /// 预览页面和字体复制在扩展自己的包里：沙盒中的扩展读不到 App 本体的文件
    private static let resources = Bundle.main.resourceURL!
    private static let previewURL = resources.appendingPathComponent("preview/preview.html")

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(images, forURLScheme: LocalImageHandler.scheme)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.navigationDelegate = self
        webView.pageZoom = DocLanguage.autoScreenScale(NSScreen.main)
        view = webView
    }

    func preparePreviewOfFile(at url: URL) async throws {
        revision += 1
        let rev = revision
        webView.pageZoom = DocLanguage.autoScreenScale(view.window?.screen ?? NSScreen.main)   // 每次预览按当时所在的屏幕算
        // 和 App 打开文件时一样识别编码（UTF-8 / UTF-16 / GB18030 / Shift-JIS 等）
        let text = MarkdownDocument.decode(try Data(contentsOf: url))
        if !ready {
            await withCheckedContinuation { c in
                waiters.append(c)
                if !loading {
                    loading = true
                    webView.loadFileURL(Self.previewURL, allowingReadAccessTo: Self.resources)
                }
            }
        }
        guard rev == revision else { return }
        guard ready else { throw CocoaError(.fileReadUnknown) }   // 页面没加载成功：交给访达显示它自己的预览
        let lang = DocLanguage.detect(text)
        let titles = Dictionary(uniqueKeysWithValues: MDCallout.allCases.map { ($0.rawValue, $0.title) })
            .merging(["blockedImage": String(localized: "网络图片未加载（隐私保护）"), "colon": String(localized: "：")]) { a, _ in a }
        let dir = url.deletingLastPathComponent().absoluteString
        _ = try await webView.callAsyncJavaScript("DropMD.render(t, b, l, u); window.scrollTo(0, 0)",
                                                  arguments: ["t": text, "b": dir, "l": lang.tag, "u": titles],
                                                  contentWorld: .page)
        guard rev == revision else { return }
        // 网页读不到文档旁边的图片：由扩展读出来交给页面（扩展能只读个人文件夹和外接硬盘，见 QuickLook.entitlements）
        let content = "document.getElementById('content')"
        if let html = try await webView.callAsyncJavaScript("return \(content).innerHTML", arguments: [:], contentWorld: .page) as? String {
            guard rev == revision else { return }
            let linked = HTMLExport.linkLocalImages(html, base: url.deletingLastPathComponent(),
                                                    scheme: LocalImageHandler.scheme, version: rev)
            images.images = linked.images
            images.revision = rev
            if !linked.images.isEmpty {
                _ = try await webView.callAsyncJavaScript("\(content).innerHTML = h", arguments: ["h": linked.html], contentWorld: .page)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading(ready: true)
    }

    /// 结束等待；加载失败或网页进程被结束时 ready 为 false，下一个文件重新加载页面
    private func finishLoading(ready: Bool) {
        self.ready = ready
        loading = false
        let w = waiters
        waiters = []
        w.forEach { $0.resume() }
    }

    // 加载失败时也要结束等待，否则访达里的预览一直转圈
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading(ready: false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoading(ready: false)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishLoading(ready: false)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        // 只允许加载预览页面本身（包括脚注等页内锚点）
        let path = action.request.url?.resolvingSymlinksInPath().path
        decisionHandler(path == Self.previewURL.resolvingSymlinksInPath().path ? .allow : .cancel)
    }
}

/// 网页滚到图片附近时才来要图片：dropmd-image:/第几次预览/第几张。只给文档里写到的图片，大图缩小后再给
final class LocalImageHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "dropmd-image"
    var images: [URL] = []
    var revision = 0
    private var stopped: Set<ObjectIdentifier> = []

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        // dropmd-image:/第几次预览/第几张：上一篇文档迟到的请求不给
        guard let requested = task.request.url, requested.pathComponents.count == 3, requested.pathComponents[1] == "\(revision)",
              let index = Int(requested.lastPathComponent), images.indices.contains(index) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let file = images[index]
        let box = TaskBox(task)
        DispatchQueue.global(qos: .userInitiated).async {
            let image = HTMLExport.previewImage(file, maxPixel: 1600)
            DispatchQueue.main.async { [self] in
                let task = box.task
                guard stopped.remove(ObjectIdentifier(task)) == nil else { return }
                guard let image else {
                    task.didFailWithError(URLError(.fileDoesNotExist))
                    return
                }
                task.didReceive(URLResponse(url: requested, mimeType: image.mime, expectedContentLength: image.data.count, textEncodingName: nil))
                task.didReceive(image.data)
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    private final class TaskBox: @unchecked Sendable {
        let task: any WKURLSchemeTask
        init(_ task: any WKURLSchemeTask) { self.task = task }
    }
}

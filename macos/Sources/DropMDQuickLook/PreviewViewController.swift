import AppKit
import Quartz
import WebKit

/// 访达里按空格（Quick Look）预览 Markdown：用 App 的预览页面（与双页预览相同）显示排版后的效果。
/// 只读文件、不联网：页面的内容安全策略禁止网络请求，点击链接也不跳转。
@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController, WKNavigationDelegate {
    private var webView: WKWebView!
    private var loaded: CheckedContinuation<Void, Never>?

    /// 预览页面和字体复制在扩展自己的包里：沙盒中的扩展读不到 App 本体的文件
    private static let resources = Bundle.main.resourceURL!
    private static let previewURL = resources.appendingPathComponent("preview/preview.html")

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.navigationDelegate = self
        view = webView
    }

    func preparePreviewOfFile(at url: URL) async throws {
        // 和 App 打开文件时一样识别编码（UTF-8 / UTF-16 / GB18030 / Shift-JIS 等）
        let text = MarkdownDocument.decode(try Data(contentsOf: url))
        await withCheckedContinuation { c in
            loaded = c
            webView.loadFileURL(Self.previewURL, allowingReadAccessTo: Self.resources)
        }
        let lang = DocLanguage.detect(text)
        let titles = Dictionary(uniqueKeysWithValues: MDCallout.allCases.map { ($0.rawValue, $0.title) })
        let dir = url.deletingLastPathComponent().absoluteString
        _ = try await webView.callAsyncJavaScript("DropMD.render(t, b, l, u)",
                                                  arguments: ["t": text, "b": dir, "l": lang.tag, "u": titles],
                                                  contentWorld: .page)
        // 网页读不到文档旁边的图片：由扩展读出来嵌进页面（扩展能只读个人文件夹和外接硬盘，见 QuickLook.entitlements）
        let content = "document.getElementById('content')"
        if let html = try await webView.callAsyncJavaScript("return \(content).innerHTML", arguments: [:], contentWorld: .page) as? String {
            let embedded = HTMLExport.embedLocalImages(html, base: url.deletingLastPathComponent(), maxPixel: 1600)
            if embedded != html {
                _ = try await webView.callAsyncJavaScript("\(content).innerHTML = h", arguments: ["h": embedded], contentWorld: .page)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    // 加载失败时也要结束等待，否则访达里的预览一直转圈
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?.resume()
        loaded = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        // 只允许加载预览页面本身（包括脚注等页内锚点）
        let path = action.request.url?.resolvingSymlinksInPath().path
        decisionHandler(path == Self.previewURL.resolvingSymlinksInPath().path ? .allow : .cancel)
    }
}

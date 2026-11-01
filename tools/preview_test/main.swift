// 预览页面测试：像 App 一样加载 preview.html，调用 App 用到的每个预览函数，任何一个抛出异常就失败。
import AppKit
import WebKit

let page = URL(fileURLWithPath: CommandLine.arguments[1])
let calls = [
    "return DropMD.render('# 日本語\\n\\n今日は **晴れ** $x^2$', '', 'ja')",
    "return DropMD.scrollToLine(2)",
    "return DropMD.exportBody('> [!TIP]\\n> 提示')",
    // 英文界面：提示框标题和网络图片说明用 App 传入的文字
    """
    DropMD.render('> [!TIP]\\n> x\\n\\n![a](https://example.com/a.png)', '', 'en', {TIP: 'Tip', blockedImage: 'Web image', colon: ': '});
    const h = document.getElementById('content').innerHTML;
    if (!h.includes('>Tip<') || !h.includes('Web image: a')) throw new Error('界面文字没有生效');
    return true
    """,
]

final class Runner: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            var failures = 0
            for js in calls {
                do {
                    _ = try await webView.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page)
                    print("ok  ", js)
                } catch {
                    failures += 1
                    print("FAIL", js, (error as NSError).userInfo["WKJavaScriptExceptionMessage"] ?? error)
                }
            }
            print(failures == 0 ? "全部通过" : "失败 \(failures) 项")
            exit(failures == 0 ? 0 : 1)
        }
    }
}

let app = NSApplication.shared
let config = WKWebViewConfiguration()
config.websiteDataStore = .nonPersistent()
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
let runner = Runner()
webView.navigationDelegate = runner
webView.loadFileURL(page, allowingReadAccessTo: URL(fileURLWithPath: "/"))
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("FAIL 预览页面 30 秒内没有加载完"); exit(1) }
app.run()

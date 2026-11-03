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
    // 文件开头的 YAML 信息显示为代码块，不变成分隔线和标题
    """
    DropMD.render('---\\ntitle: 测试\\n---\\n\\n正文', '', 'zh-Hans');
    const h = document.getElementById('content').innerHTML;
    if (h.includes('<hr') || h.includes('<h2') || !h.includes('title: 测试')) throw new Error('YAML 信息显示错了：' + h);
    return true
    """,
    // AI 常写的中文粗体（结尾贴着标点、后面紧跟中文）、\\( \\) 公式、1. 下嵌套 3 格的列表
    """
    DropMD.render('这是**“重点”**内容，参见**结论（重要）**以及 \\\\(x^2\\\\)\\n\\n1. 一\\n   - 子项\\n2. 二', '', 'zh-Hans');
    const h = document.getElementById('content').innerHTML;
    if (h.includes('**')) throw new Error('中文粗体没有生效：' + h);
    if (!h.includes('katex')) throw new Error('\\\\( \\\\) 公式没有显示：' + h);
    if ((h.match(/<ol/g) || []).length !== 1) throw new Error('嵌套列表被拆开了：' + h);
    return true
    """,
    // 导出的 HTML 保留网络图片（预览里为保护隐私不加载）
    """
    if (!DropMD.exportBody('![a](https://example.com/a.png)').includes('<img src="https://example.com/a.png"')) throw new Error('导出时网络图片丢了');
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

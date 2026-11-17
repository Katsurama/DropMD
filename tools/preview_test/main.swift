// 预览页面测试：像 App 一样加载 preview.html，调用 App 用到的每个预览函数，任何一个抛出异常就失败。
import AppKit
import WebKit

let page = URL(fileURLWithPath: CommandLine.arguments[1])
let calls = [
    "return DropMD.render('# 日本語\\n\\n今日は **晴れ** $x^2$', '', 'ja')",
    "return DropMD.scrollToLine(2)",
    // 公式块后面同一行还有文字时，文字不能丢
    """
    DropMD.render('$$a$$ 后面的字\\n\\n$$\\nb\\n$$ 也在', '', 'zh-Hans');
    const t = document.getElementById('content').textContent;
    if (!t.includes('后面的字') || !t.includes('也在')) throw new Error('公式后的文字丢了：' + t);
    return true
    """,
    "return DropMD.exportBody('> [!TIP]\\n> 提示')",
    // 英文界面：提示框标题和网络图片说明用 App 传入的文字
    """
    DropMD.render('> [!TIP]\\n> x\\n\\n![a](https://example.com/a.png)', '', 'en', {TIP: 'Tip', blockedImage: 'Web image', colon: ': '});
    const h = document.getElementById('content').innerHTML;
    if (!h.includes('>Tip<') || !h.includes('Web image: a')) throw new Error('界面文字没有生效');
    return true
    """,
    // 代码块的复制按钮：App 的预览里有（传了按钮文字），点了把代码交给 App；快速查看（没传文字）不加
    """
    DropMD.render('```\\nab\\n```', '', 'zh-Hans');
    if (document.querySelector('.copy-code')) throw new Error('没传按钮文字时不该加复制按钮');
    DropMD.render('```\\nab\\n```', '', 'zh-Hans', {copyCode: '复制代码', copied: '已复制'});
    const b = document.querySelector('pre .copy-code');
    if (!b) throw new Error('代码块没有复制按钮');
    b.click();
    if (b.textContent !== '已复制') throw new Error('点了复制按钮没有变成“已复制”');
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
/// 和 App 一样接收复制按钮传来的文字，检查传的是代码本身
final class CopyStub: NSObject, WKScriptMessageHandler {
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.body as? String != "ab" { print("FAIL 复制的文字不对：", message.body); exit(1) }
    }
}
let config = WKWebViewConfiguration()
config.websiteDataStore = .nonPersistent()
config.userContentController.add(CopyStub(), name: "copy")
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
let runner = Runner()
webView.navigationDelegate = runner
webView.loadFileURL(page, allowingReadAccessTo: URL(fileURLWithPath: "/"))
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("FAIL 预览页面 30 秒内没有加载完"); exit(1) }
app.run()

// 预览页面测试：像 App 一样加载 preview.html，调用 App 用到的每个预览函数，任何一个抛出异常就失败。
import AppKit
import WebKit

let page = URL(fileURLWithPath: CommandLine.arguments[1])
let calls = [
    // 导出 HTML 不先排版预览：提示框标题直接用 App 传入的文字（放在最前面，之前没调用过 render）
    """
    if (!DropMD.exportBody('> [!TIP]\\n> x', {TIP: 'Hint'}).includes('>Hint<')) throw new Error('导出时提示框标题没用传入的文字');
    return true
    """,
    "return DropMD.render('# 日本語\\n\\n今日は **晴れ** $x^2$', '', 'ja')",
    // 公式块后面同一行还有文字时，文字不能丢
    """
    DropMD.render('$$a$$ 后面的字\\n\\n$$\\nb\\n$$ 也在', '', 'zh-Hans');
    const t = document.getElementById('content').textContent;
    if (!t.includes('后面的字') || !t.includes('也在')) throw new Error('公式后的文字丢了：' + t);
    return true
    """,
    // 文档目录用作相对图片的 base 时，脚注和回跳仍锚定在 Quick Look 预览页。
    """
    DropMD.render('正文[^1]\\n\\n[^1]: 脚注', 'file:///tmp/dropmd-preview-assets/', 'zh-Hans');
    const ref = document.querySelector('.footnote-ref a');
    const back = document.querySelector('.footnote-backref');
    const page = location.href.split('#')[0];
    if (ref?.href !== page + '#fn1' || back?.href !== page + '#fnref1') throw new Error('脚注目标不在预览页');
    return true
    """,
    // 导出的 HTML 不带只给预览用的行号
    """
    const h = DropMD.exportBody('# a\\n\\n$$\\nx\\n$$');
    if (h.includes('data-line')) throw new Error('导出带了 data-line：' + h);
    return DropMD.exportBody('> [!TIP]\\n> 提示')
    """,
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
    // 导出的 HTML 保留网络图片（预览里为保护隐私不加载），预览同时拦截原始 HTML <img> 且转义提示框标题
    """
    if (!DropMD.exportBody('![a](https://example.com/a.png)').includes('<img src="https://example.com/a.png"')) throw new Error('导出时网络图片丢了');
    DropMD.render('<img src="https://example.com/a.svg" alt="徽章">\\n\\n> [!NOTE]\\n> 正文', '', '', { NOTE: '<b>笔记</b>' });
    const c = document.getElementById('content').innerHTML;
    if (c.includes('<img') || !c.includes('blocked-image') || !c.includes('徽章')) throw new Error('原始 HTML 远程图片没有在预览里拦截：' + c);
    if (c.includes('<b>笔记</b>') || !c.includes('&lt;b&gt;笔记&lt;/b&gt;')) throw new Error('提示框标题未按纯文本转义：' + c);
    if (!DropMD.exportBody('<img src="https://example.com/a.svg" alt="徽章">').includes('<img src="https://example.com/a.svg"')) throw new Error('导出时原始 HTML 网络图片丢了');
    DropMD.render('<img srcset="https://example.com/a.png 1x" alt="高清图">\\n\\n<picture><source srcset="https://example.com/a.webp"><img src="local.png"></picture>', '', '', {});
    const c2 = document.getElementById('content').innerHTML;
    if (c2.includes('<source') || c2.includes('srcset') || !c2.includes('blocked-image') || !c2.includes('高清图') || !c2.includes('<img src="local.png">')) throw new Error('原始 HTML 远程 srcset 没有在预览里拦截：' + c2);
    if (!DropMD.exportBody('<img srcset="https://example.com/a.png 1x" alt="高清图">').includes('https://example.com/a.png')) throw new Error('导出时远程 srcset 丢了');
    return true
    """,    // 找不到的本地图片换成占位框，不留空图片框
    """
    DropMD.render('![微信赞赏码](no-such-dir/missing.png)', '', 'zh-Hans', {missingImage: '找不到图片', colon: '：'});
    for (let i = 0; i < 50 && document.querySelector('#content img'); i++) await new Promise(r => setTimeout(r, 20));
    const c = document.getElementById('content').innerHTML;
    if (c.includes('<img') || !c.includes('找不到图片：微信赞赏码')) throw new Error('找不到的图片没有换成占位框：' + c);
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

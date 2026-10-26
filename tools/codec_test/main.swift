import Foundation

var failures = 0
func check(_ name: String, _ input: String, _ expected: String? = nil) {
    let blocks = MarkdownCodec.parse(input)
    let out = MarkdownCodec.serialize(blocks)
    let want = expected ?? input
    // 再次往返必须稳定
    let again = MarkdownCodec.serialize(MarkdownCodec.parse(out))
    if out != want || again != out {
        failures += 1
        print("FAIL \(name)\n--- want\n\(want)--- got\n\(out)--- again\n\(again)")
    } else {
        print("ok   \(name)")
    }
}

check("heading+para", "# 标题\n\n正文 **粗体** 和 *斜体*。\n")
check("lists", "- a\n- b\n  - c\n\n1. x\n2. y\n")
check("tasks", "- [ ] 未完成\n- [x] 已完成\n")
check("quote", "> 引用一\n> 引用二\n")
check("code", "```swift\nlet a = 1\n```\n")
check("table", "| 列 1 | 列 2 |\n| --- | --- |\n| a | b\\|c |\n")
check("rule", "上\n\n---\n\n下\n")
check("link+image", "看 [官网](https://example.com) 和 ![图](images/a%20b.png)\n")
check("underline+strike", "<u>下划线</u> ~~删除~~ `code`\n")
check("math", "公式 $E=mc^2$ 与金额 \\$5\n")
check("rawhtml", "<div>\n原样\n</div>\n")
check("mathblock", "$$\nx^2\n$$\n")
check("escapes", "a\\*b snake_case \\_x\\_ 1. 不是列表\n")
check("nested", "***粗斜*** **粗 *斜* 粗**\n")
check("empty para", "a\n\n&nbsp;\n\nb\n")
check("soft wrap", "第一行\n第二行\n", "第一行 第二行\n")
check("4-space nested", "- a\n    - b\n", "- a\n  - b\n")
check("star bullets", "* a\n* b\n", "- a\n- b\n")
check("heading closing", "## 标题 ##\n", "## 标题\n")
check("crlf", "a\r\n\r\nb\r\n", "a\n\nb\n")
check("empty", "", "")
check("hash text", "\\# 不是标题\n")

// 模型 → Markdown：样式边界与空白
let runs = [MDRun(text: "粗体 ", bold: true), MDRun(text: "普通"), MDRun(text: " 斜", italic: true)]
let s = MarkdownCodec.inline(runs)
print(s == "**粗体** 普通 *斜*" ? "ok   whitespace" : "FAIL whitespace: \(s)")
if s != "**粗体** 普通 *斜*" { failures += 1 }
let adj = MarkdownCodec.inline([MDRun(text: "a", bold: true), MDRun(text: "b", bold: true, underline: true)])
print(adj == "**a<u>b</u>**" ? "ok   adjacent" : "FAIL adjacent: \(adj)")
if adj != "**a<u>b</u>**" { failures += 1 }

check("bullet then ordered nested", "- a\n  1. x\n  2. y\n- b\n")
check("triple fallback", "***a* b**\n")
check("highlight", "==重点== a = b, x \\=\\= y\n")
check("footnote", "正文[^1]\n\n[^1]: 脚注内容\n")
check("details", "<details>\n<summary>点击展开 & 查看</summary>\n\n- 项目\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n</details>\n", "<details>\n<summary>点击展开 &amp; 查看</summary>\n\n- 项目\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n</details>\n")
check("details nested", "前\n\n<details><summary>外</summary>\n\n<details>\n<summary>内</summary>\n\n内容\n\n</details>\n\n</details>\n\n后\n", "前\n\n<details>\n<summary>外</summary>\n\n<details>\n<summary>内</summary>\n\n内容\n\n</details>\n\n</details>\n\n后\n")
check("sup sub kbd", "H<sub>2</sub>O 与 x<sup>2</sup>，按 <kbd>⌘S</kbd> 保存\n")
check("line break", "第一行<br>第二行\n")
check("html tags", "<b>粗</b> <mark>亮</mark>\n", "**粗** ==亮==\n")
check("literal tag", "\\<sup>不是上标\n")
check("callout", "> [!NOTE]\n> 提示内容\n")
check("two callouts", "> [!TIP]\n> 一\n\n> [!WARNING]\n> 二\n")
check("callout warning", "> [!WARNING]\n> 小心\n\n正文\n")
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)

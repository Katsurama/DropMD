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
check("soft wrap", "第一行\n第二行\n")
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
// 换行后的一行会被读成列表、标题时改回空格
let soft = MarkdownCodec.serialize([.line(MDLine(kind: .body, runs: [MDRun(text: "a\n- b\n=\nc")]))])
print(soft == "a - b =\nc\n" ? "ok   soft break fallback" : "FAIL soft break fallback: \(soft)")
if soft != "a - b =\nc\n" { failures += 1 }

check("bullet then ordered nested", "- a\n  1. x\n  2. y\n- b\n")
check("triple fallback", "***a* b**\n")
check("highlight", "==重点== a = b, x \\=\\= y\n")
check("footnote", "正文[^1]\n\n[^1]: 脚注内容\n")
check("details", "<details>\n<summary>点击展开 & 查看</summary>\n\n- 项目\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n</details>\n", "<details>\n<summary>点击展开 &amp; 查看</summary>\n\n- 项目\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n</details>\n")
// 单页表示不了的写法：原样保存，或换成意思相同的写法
check("YAML 信息", "---\ntitle: 测试\ntags: [a, b]\n---\n\n正文\n")
check("引用式链接", "见[说明][1]和[另一个][]。\n\n[1]: https://example.com \"标题\"\n[另一个]: https://example.org\n")
check("强制换行", "行一  \n行二\\\n行三\n", "行一<br>行二<br>行三\n")
check("行尾的普通反斜杠", "路径 C:\\\\\n下一行\n")
check("链接和图片的提示文字", "见[说明](https://example.com \"标题\")和![图](a.png 'b')。\n")
check("中文段落里的换行", "第一行\n第二行，**粗\n体**\n第三行\n")
check("标题里的换行", "标题\n接着\n===\n", "# 标题 接着\n")
check("多行脚注", "正文[^1]\n\n[^1]: 第一行\n    第二行\n\n    第二段\n\n后面\n")
check("一行脚注后接正文", "[^1]: 脚注\n\n正文\n")
check("缩进代码", "正文\n\n    代码 1\n\n    代码 2\n", "正文\n\n```\n代码 1\n\n代码 2\n```\n")
check("编号从 5 开始", "5. 五\n6. 六\n")
check("编号被代码打断", "1. 一\n\n```\nx\n```\n\n2. 二\n")
check("编号里有嵌套", "1. 一\n  - 子项\n2. 二\n", "1. 一\n   - 子项\n2. 二\n")
// 下一层缩进到上一层的文字开头，否则其他软件会读成同级
check("编号下嵌套 3 格", "1. 第一步\n   - 子项 a\n   - 子项 b\n2. 第二步\n")
check("两位编号下嵌套 4 格", "10. 十\n    - 子项\n")
check("三层混合", "1. 一\n   - 二\n     1. 三\n")
check("待办下嵌套 2 格", "- [ ] 待办\n  - 子项\n")
// 列表项里的代码块（AI 常写）：拆成列表项和代码块，保存时缩进回去，编号接着数
check("列表项里的代码块", "1. 安装：\n\n   ```bash\n   npm i\n   ```\n\n2. 运行\n")
check("无序列表里的代码块", "- 例子：\n\n  ```python\n  print(1)\n\n  x = 2\n  ```\n\n- 下一项\n")
check("代码块在最后一项", "1. 一\n2. 二：\n\n   ```\n   code\n   ```\n")
check("两位编号的代码块", "10. 十：\n\n    ```\n    x\n    ```\n\n11. 十一\n")
check("列表后面不缩进的代码块不归列表", "1. 一\n\n```\nx\n```\n")
// 还有续段时仍整块原样保存
check("列表项里有续段和代码", "1. 一\n\n   续段\n\n   ```\n   x\n   ```\n")
// AI 工具常用的公式写法
check("行内 \\( \\)", "质能方程 \\(E=mc^2\\) 很有名。\n")
check("公式块 \\[ \\]", "\\[\n\\int_0^1 x\\,dx = \\frac12\n\\]\n")
check("单行 \\[ \\]", "\\[ a^2+b^2=c^2 \\]\n")
check("没有结尾的 \\(", "括号 \\(不是公式\n", "括号 (不是公式\n")
check("引用里的列表", "> 引用\n>\n> - 列表\n>   - 嵌套\n")
check("列表续段", "- 一\n\n  续段\n- 二\n")
check("列表里的代码", "1. 一\n   ```\n   代码\n   ```\n2. 二\n")
check("表格对齐", "| 左 | 中 | 右 | 默认 |\n| :-- | :-: | --: | --- |\n| 1 | 2 | 3 | 4 |\n")
check("下划线式标题", "标题\n===\n\n副标题\n---\n\n正文\n\n---\n", "# 标题\n\n## 副标题\n\n正文\n\n---\n")
check("列表续行", "- 一\n接着写\n- 二\n", "- 一\n  接着写\n- 二\n")
check("列表续行（缩进）", "- 一\n  接着写\n  - 子项\n    子项续行\n\n1. 编号\n   续行\n\n- [ ] 待办\n      续行\n")
check("引用续行不带 >", "> 引用一\n接着写\n\n正文\n", "> 引用一\n> 接着写\n\n正文\n")
check("引用空行后的正文", "> 引用\n>\n正文\n", "> 引用\n>\n\n正文\n")
check("details open", "<details open>\n<summary>标题</summary>\n\n内容\n\n</details>\n")
check("details nested", "前\n\n<details><summary>外</summary>\n\n<details>\n<summary>内</summary>\n\n内容\n\n</details>\n\n</details>\n\n后\n", "前\n\n<details>\n<summary>外</summary>\n\n<details>\n<summary>内</summary>\n\n内容\n\n</details>\n\n</details>\n\n后\n")
check("sup sub kbd", "H<sub>2</sub>O 与 x<sup>2</sup>，按 <kbd>⌘S</kbd> 保存\n")
check("line break", "第一行<br>第二行\n")
check("html tags", "<b>粗</b> <mark>亮</mark>\n", "**粗** ==亮==\n")
check("literal tag", "\\<sup>不是上标\n")
check("callout", "> [!NOTE]\n> 提示内容\n")
check("two callouts", "> [!TIP]\n> 一\n\n> [!WARNING]\n> 二\n")
check("callout warning", "> [!WARNING]\n> 小心\n\n正文\n")
// [[双链]]：AI 工具的记忆、笔记常用，不能转义
check("双链", "见 [[读书会]] 和 ![[图.png]]。\n")
check("双链 别名和小节", "[[笔记#小节|别名]] [[a_b]] [[_下划线_]]\n")
check("双链 里的符号不算格式", "[[a*b]] 和 *斜体* [[c`d]] [[e$f]] [[g*h]]\n")
check("双链 在粗体里", "**见 [[读书会]] 后** ~~[[旧]]~~\n")
check("双链 在列表引用标题", "# [[标题]]\n\n- [[项]]\n- [ ] [[待办]]\n\n> [[引用]]\n")
check("双链 在表格", "| [[甲\\|别名]] | [[乙]] |\n| --- | --- |\n| [[丙]] | b |\n")
check("斜体跨过双链", "*a [[b*c]] d*\n")
check("多行正文", "[[一]]\n[[二]]\n")
check("已被转义的双链恢复", "见 \\[\\[读书会\\]\\]。\n", "见 [[读书会]]。\n")
check("转义的括号后面跟 ( 不能变成链接", "\\[\\[a\\]\\](b)\n")
check("转义的括号后面跟 [ ", "\\[\\[a\\]\\]\\[b\\]\n")
check("链接文字带方括号", "[\\[a\\]](https://example.com)\n")
check("数组写法仍转义", "见 \\[\\[1,2\\],\\[3,4\\]\\]\n")
check("空的双括号仍转义", "见 \\[\\[\\]\\]\n")
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)

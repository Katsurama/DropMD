// 单页编辑器的按键行为测试：在离屏的编辑区中模拟输入、回车、Tab、退格，检查得到的 Markdown。
import AppKit

/// 测试中不需要真正的编辑器窗口控制器（EditorAction.swift 引用了这个类型）
@MainActor final class EditorController { func perform(_ a: EditorAction) {} }
struct FileItem { let url: URL; let relativePath: String }

@MainActor func makeView(_ md: String) -> RichTextView {
    let storage = NSTextStorage()
    let layout = RichLayoutManager()
    storage.addLayoutManager(layout)
    let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
    layout.addTextContainer(container)
    let tv = RichTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
    tv.isRichText = true; tv.allowsUndo = true
    storage.setAttributedString(RichBridge.attributed(markdown: md, baseURL: nil))
    tv.typingAttributes = storage.length > 0 ? storage.attributes(at: 0, effectiveRange: nil) : RichStyle.typingAttributes(for: .body)
    return tv
}
@MainActor func type(_ tv: RichTextView, _ s: String) {
    for ch in s { tv.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
}
@MainActor func md(_ tv: RichTextView) -> String { RichBridge.markdown(from: tv.textStorage!) }
/// 给编辑区一个撤销管理器（测撤销用；每次操作单独成组，与真实按键相同）
final class UndoHost: NSObject, NSTextViewDelegate {
    let um = UndoManager()
    override init() { super.init(); um.groupsByEvent = false }
    func undoManager(for view: NSTextView) -> UndoManager? { um }
}
@MainActor func step(_ host: UndoHost, _ body: () -> Void) {
    host.um.beginUndoGrouping()
    body()
    host.um.endUndoGrouping()
}
var failures = 0
@MainActor func check(_ name: String, _ got: String, _ want: String) {
    let ok = got == want
    if !ok { failures += 1 }
    print(ok ? "ok  " : "FAIL", name, ok ? "" : "\n     got:  \(got.debugDescription)\n     want: \(want.debugDescription)")
}

MainActor.assumeIsolated {
    for (prefix, want) in [("-", "- 项目\n"), ("*", "- 项目\n"), (">", "> 项目\n"), ("1.", "1. 项目\n"), ("#", "# 项目\n"),
                           ("[]", "- [ ] 项目\n"),
                           // 中文输入法下的符号
                           ("－", "- 项目\n"), ("》", "> 项目\n"), ("1。", "1. 项目\n"), ("【】", "- [ ] 项目\n"), ("＃", "# 项目\n")] {
        let tv = makeView("")
        type(tv, prefix + " 项目")
        check("自动格式 \(prefix)", md(tv), want)
    }
    // 插入提示框：内容被选中，直接输入替换；接在另一个提示框后时保存为两个
    do {
        let tv = makeView("> [!TIP]\n> 一\n")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length - 1, length: 0))
        tv.insertCallout(.warning); type(tv, "二")
        check("插入提示框", md(tv), "> [!TIP]\n> 一\n\n> [!WARNING]\n> 二\n")
    }
    // 提示框标题显示为中文，保存时写回原文；标题后输入的文字另起一段，不被吞掉
    do {
        let tv = makeView("> [!tip]\n> 一\n")
        check("提示框标题显示", tv.string, "提示\n一\n")
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        tv.insertNewline(nil); type(tv, "二")
        check("提示框标题后输入", md(tv), "> [!tip]\n> 二\n> 一\n")
    }
    // 链接、图片的提示文字，段落里的单个换行，多行脚注：保存后不变
    for src in ["见[说明](https://example.com \"标题\")和![图](a.png 'b')。\n",
                "第一行\n第二行，**粗\n体**\n",
                "正文[^1]\n\n[^1]: 第一行\n    第二行\n\n    第二段\n",
                "1. 安装：\n\n   ```bash\n   npm i\n   ```\n\n2. 运行\n",
                "- 一\n  ```\n  x\n  ```\n- 二\n",
                "见 [[读书会]] 和 **[[笔记#小节|别名]]**。\n",
                "[![徽章](a.png \"图\")](https://example.com \"链\") [![b](https://x.io/%E5%B9%B3%2B.svg)](#b)\n"] {
        check("单页往返 \(src.prefix(4).replacingOccurrences(of: "\n", with: " "))", md(makeView(src)), src)
    }
    // 带链接的图片后面打字：字不进链接，图片也不丢；相邻的相同图片各保留一张
    do {
        let src = "[![徽章](a.png)](https://example.com)\n"
        let tv = makeView(src)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length - 1, length: 0))
        type(tv, "字")
        check("带链接的图片后打字", md(tv), "[![徽章](a.png)](https://example.com)字\n")
        let same = "![a](x.png)![a](x.png)\n"
        check("相邻的相同图片", md(makeView(same)), same)
        let plain = makeView("![a](a.png)\n")
        plain.setSelectedRange(NSRange(location: (plain.string as NSString).length - 1, length: 0))
        type(plain, "字")
        check("图片后打字", md(plain), "![a](a.png)字\n")
        let typedAt = (plain.string as NSString).range(of: "字").location
        check("图片后打字的字号", "\((plain.textStorage!.attribute(.font, at: typedAt, effectiveRange: nil) as? NSFont)?.pointSize ?? 0)", "\(RichStyle.baseFont(for: .body).pointSize)")
    }
    // 编码：没改内容时字节不变；改了也用回原编码；识别不出就不打开
    do {
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let zh = "# 标题\r\n中文内容\n", ja = "# 見出し\n日本語の文章です。\n"
        let files: [(String, Data)] = [
            ("UTF-8", Data(zh.utf8)), ("UTF-8 BOM", Data([0xEF, 0xBB, 0xBF]) + Data(zh.utf8)),
            ("UTF-16LE", Data([0xFF, 0xFE]) + zh.data(using: .utf16LittleEndian)!), ("UTF-16BE", Data([0xFE, 0xFF]) + zh.data(using: .utf16BigEndian)!),
            ("GB18030", zh.data(using: gb)!), ("Shift-JIS", ja.data(using: .shiftJIS)!), ("EUC-JP", ja.data(using: .japaneseEUC)!),
            ("坏的 UTF-8", Data([0x61, 0xE4, 0xB8, 0x62, 0xFF, 0xFE, 0x80, 0x81])),
        ]
        for (name, bytes) in files {
            check("编码不改不变 \(name)", (try? MarkdownDocument(data: bytes).data()) == bytes ? "同" : "变了", "同")
        }
        var doc = try! MarkdownDocument(data: zh.data(using: gb)!)
        doc.text += "新"
        check("改后用回原编码", String(data: doc.data(), encoding: gb) ?? "", zh + "新")
        var bomDoc = try! MarkdownDocument(data: Data([0xEF, 0xBB, 0xBF]) + Data("a\n".utf8))
        check("BOM 不进文字", bomDoc.text, "a\n")
        bomDoc.text = "b\n"
        check("改后保留 BOM", "\(bomDoc.data().prefix(3) == Data([0xEF, 0xBB, 0xBF]))", "true")
        var sjis = try! MarkdownDocument(data: ja.data(using: .shiftJIS)!)
        sjis.text += "😀"
        check("原编码写不下：存成 UTF-8 不丢字", String(data: sjis.data(), encoding: .utf8) ?? "", ja + "😀")
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48, 0x44, 0x52, 0, 0, 1, 0])
        check("识别不出就不打开", (try? MarkdownDocument(data: png)) == nil ? "不打开" : "打开了", "不打开")
        check("快速查看仍尽量显示", MarkdownDocument.decode(png).isEmpty ? "空" : "有内容", "有内容")
        // 正常的 UTF-8 坏了几个字节：不打开，不要猜成别的编码显示乱码；快速查看仍尽量显示
        var damaged = Data(String(repeating: "中文内容第二行，", count: 20).utf8)
        damaged[30] = 0xFF
        check("损坏的 UTF-8 不打开", (try? MarkdownDocument(data: damaged)) == nil ? "不打开" : "打开了", "不打开")
        check("损坏的 UTF-8 快速查看能看", MarkdownDocument.decode(damaged).contains("第二行") ? "能看" : "乱码", "能看")
        check("正常 GB18030 不算损坏", (try? MarkdownDocument(data: String(repeating: "中文内容第二行，", count: 20).data(using: gb)!).text.hasPrefix("中文")) == true ? "能开" : "打不开", "能开")
        check("正常 Latin-1 不算损坏", (try? MarkdownDocument(data: "café déjà vu\n".data(using: .isoLatin1)!).text.hasPrefix("caf")) == true ? "能开" : "打不开", "能开")
        // 没有 BOM 的 UTF-16：能打开，保存后字节不变
        for (name, e) in [("小端", String.Encoding.utf16LittleEndian), ("大端", .utf16BigEndian)] {
            let raw = "# Title\nsome 中文 text\n".data(using: e)!
            let d = try? MarkdownDocument(data: raw)
            check("无 BOM UTF-16 \(name)", "\(d?.text.hasPrefix("# Title") == true) \(d?.data() == raw)", "true true")
            let ascii = "# Title\r\n\r\nASCII body\t\n"
            let asciiData = ascii.data(using: e)!
            var asciiDoc = try! MarkdownDocument(data: asciiData)
            check("ASCII 无 BOM UTF-16 \(name) 解码", asciiDoc.text, ascii)
            check("ASCII 无 BOM UTF-16 \(name) 字节往返", "\(asciiDoc.data() == asciiData)", "true")
            asciiDoc.text += "新的内容"
            check("ASCII 无 BOM UTF-16 \(name) 改后保留编码", "\(asciiDoc.data() == asciiDoc.text.data(using: e))", "true")
        }
        for input in ["# ASCII\r\n", "# 文本\n", "a\0bc", "a\0é"] {
            let raw = Data(input.utf8)
            let doc = try! MarkdownDocument(data: raw)
            check("UTF-8 不误判：\(input.debugDescription)", doc.text, input)
            check("UTF-8 字节往返：\(input.debugDescription)", "\(doc.data() == raw)", "true")
        }
        check("新文档是 UTF-8", String(data: MarkdownDocument(text: "新").data(), encoding: .utf8) ?? "", "新")
    }
    // 在原样内容后面打字是普通文字；列表显示的编号和文件一致；图片文件名编码
    do {
        for (src, want) in [("<span>红</span>\n", "<span>红</span>\\*字\\*\n"), ("正文[^1]\n\n[^1]: 说明\n", "正文[^1]\\*字\\*\n\n[^1]: 说明\n")] {
            let tv = makeView(src)
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "\n").location, length: 0))
            type(tv, "*字*")
            check("原样内容后打字 \(src.prefix(6).debugDescription)", md(tv), want)
        }
        let tv = makeView("5. 五\n6. 六\n\n正文\n\n3. 三\n4. 四\n\n- 项\n\n1. 甲\n2. 乙\n")
        let s = tv.textStorage!, ns = s.string as NSString
        let shown = ["五", "六", "三", "四", "甲", "乙"].map { ch -> Int in
            (tv.layoutManager as! RichLayoutManager).number(at: ns.range(of: ch).location, depth: 0, in: s)
        }
        check("列表显示的编号", "\(shown)", "[5, 6, 3, 4, 1, 2]")
        check("图片文件名编码", RichTextView.encodedImagePath("a%b#c?d 图.png"), "a%25b%23c%3Fd 图.png")
    }
    // 同一批重名的文件：输出不能重复，否则后转换的会覆盖先转换的
    do {
        let names = ["a.docx", "a.pdf", "a_pdf.docx", "a.PDF", "a_pdf.html"]
        let items = names.map { FileItem(url: URL(fileURLWithPath: "/d/" + $0), relativePath: $0) }
        check("重名文件的输出", Planner.plan(items, outDir: nil).map(\.lastPathComponent).joined(separator: " "),
              "a.md a_pdf.md a_pdf_docx.md a_pdf_2.md a_pdf_html.md")
    }
    // 走真实编辑区：没改过的段落保持原文（写法、空行都不变）
    do {
        let src = "价格 $99\n# 标题\n路径 C:\\Users\\a\n\n\n```python title=\"a.py\"\nx\n```\n1. 甲\n1. 乙\n\n改这里\n\n<span>尾</span>"
        let tv = makeView(src)
        check("不改保持原文", MarkdownCodec.serialize(RichBridge.blocks(from: tv.textStorage!), preserving: src), src)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "改这里").location + 3, length: 0))
        type(tv, "字")
        check("只改一段其他不变", MarkdownCodec.serialize(RichBridge.blocks(from: tv.textStorage!), preserving: src),
              src.replacingOccurrences(of: "改这里", with: "改这里字"))
        for name in ["editor_sample.md", "editor_sample.en.md"] {
            let sample = (try? String(contentsOfFile: "packaging/samples/" + name, encoding: .utf8)) ?? ""
            let v = makeView(sample)
            check("样例不改保持原文 \(name)", MarkdownCodec.serialize(RichBridge.blocks(from: v.textStorage!), preserving: sample) == sample && !sample.isEmpty ? "同" : "不同", "同")
        }
    }
    // 相邻的同类段落：改别处再保存，不能合成一个、不能变样
    for (name, body) in [
        ("相邻代码块不同语言", "```sh\na\n```\n\n```py\nb\n```\n"), ("相邻代码块同语言", "```sh\na\n```\n\n```sh\nb\n```\n"),
        ("紧挨的代码块", "```sh\na\n```\n```py\nb\n```\n"), ("相邻引用", "> a\n\n> b\n"), ("相邻列表不同类", "- a\n\n1. b\n"),
        ("相邻表格", "| a |\n| --- |\n| 1 |\n\n| b |\n| --- |\n| 2 |\n"), ("相邻 HTML", "<div>a</div>\n\n<div>b</div>\n"), ("编号待办改字", "3. [ ] 一\n"),
        ("相邻公式", "$$a$$\n\n$$b$$\n"), ("相邻折叠", "<details><summary>s</summary>\n\nx\n\n</details>\n\n<details><summary>t</summary>\n\ny\n\n</details>\n"),
        ("内嵌图片", "![](data:image/png;base64,iVBORw0KGgo=)\n"),
        // 其他常见写法
        ("嵌套引用", "> 外\n>\n> > 内\n"), ("引用里的代码块", "> ```js\n> x\n> ```\n"), ("列表后的代码块", "- a\n\n```sh\nb\n```\n"),
        ("表格后的列表", "| a |\n| --- |\n| 1 |\n\n- b\n"), ("HTML 注释", "<!-- 注释 -->\n\n正文\n"), ("脚注定义", "正文[^1]\n\n[^1]: 说明\n"),
        ("标题结尾 #", "## 标题 ##\n"), ("下划线强调", "_斜_ 和 __粗__\n"), ("尖括号链接", "<https://example.com>\n"),
        ("行尾两空格换行", "一  \n二\n"), ("编号用括号", "1) 一\n2) 二\n"), ("编号里的待办", "1. [ ] 一\n2. [x] 二\n"),
        ("星号分隔线", "***\n"), ("下划线分隔线", "___\n"), ("TOML 开头", "+++\ntitle = \"a\"\n+++\n\n正文\n"),
        ("br 换行", "一<br>二\n"), ("表格里的公式", "| a |\n| --- |\n| $x$ |\n"), ("转义竖线", "| a\\|b |\n| --- |\n| 1 |\n"),
        ("Tab 缩进列表", "- a\n\t- b\n"), ("加号列表", "+ a\n+ b\n"), ("引用里的列表", "> - a\n> - b\n"),
        ("待办嵌套", "- [ ] a\n  - [x] b\n"), ("链接定义", "[a][1]\n\n[1]: https://example.com \"标题\"\n"),
        ("图片带尺寸 HTML", "<img src=\"a.png\" width=\"200\">\n"), ("删除线单波浪", "~删~\n"), ("行内代码里的反引号", "`` a`b ``\n"),
        ("缩进代码块", "    code\n    more\n"), ("emoji 短码", ":smile: 好\n"), ("全角标点", "（括号）、“引号”。\n"),
        ("Mermaid", "```mermaid\ngraph TD\nA-->B\n```\n"), ("波浪线围栏", "~~~py\nx\n~~~\n"), ("四个反引号", "````md\n```\nx\n```\n````\n"),
    ] {
        let src = "改这里\n\n" + body
        // 在这段里面打字：保存后重新打开，显示的内容要和保存前一样（写法可以变，意思不能变）
        do {
            let tv = makeView(src)
            tv.setSelectedRange(NSRange(location: 4, length: 0))
            type(tv, "字")
            let saved = MarkdownCodec.serialize(RichBridge.blocks(from: tv.textStorage!), preserving: src)
            // 空行、换行可以变；在待办方框前打的字会挪到方框后面，方框单独数
            let plain = { (s: String) in s.filter { !$0.isWhitespace && $0 != "☐" && $0 != "☑" } + s.filter { $0 == "☐" || $0 == "☑" } }
            check("\(name) 段内改字后重开", plain(makeView(saved).string), plain(tv.string))
        }
        let tv = makeView(src)
        check("\(name) 不改", MarkdownCodec.serialize(RichBridge.blocks(from: tv.textStorage!), preserving: src), src)
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        type(tv, "字")
        check("\(name) 改别处", MarkdownCodec.serialize(RichBridge.blocks(from: tv.textStorage!), preserving: src), "改这里字\n\n" + body)
    }
    // 段内改字后的文件内容：编号待办留编号；公式块、分隔线那一行打的字单独成段，公式和分隔线不丢
    for (src, word, want) in [("3. [ ] 一\n", "一", "3. [ ] 一字\n"), ("1. [ ] 一\n2. [x] 二\n", "二", "1. [ ] 一\n2. [x] 二字\n")] {
        let tv = makeView(src)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: word).location + 1, length: 0))
        type(tv, "字")
        check("编号待办改字 \(src.debugDescription)", MarkdownCodec.serialize(RichBridge.blocks(from: tv.textStorage!), preserving: src), want)
    }
    for (src, want) in [("$$a$$\n", "字\n\n$$a$$\n"), ("***\n", "字\n\n***\n"), ("- [ ] 一\n", "- [ ] 字一\n")] {
        let tv = makeView(src)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        type(tv, "字")
        check("行首打字 \(src.debugDescription)", MarkdownCodec.serialize(RichBridge.blocks(from: tv.textStorage!), preserving: src), want)
    }
    // 代码块后面的段落设成代码块：屏幕上连成一块，保存也是一块；原来就分开的两块仍分开
    do {
        let tv = makeView("```\na\n```\n\n乙\n")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "乙").location, length: 0))
        tv.setKind(.code(""))
        check("代码块后新设的代码块并进去", md(tv), "```\na\n乙\n```\n")
        let two = makeView("```sh\na\n```\n\n```py\nb\n```\n")
        let gap = (two.string as NSString).range(of: "\n\n").location + 1
        two.setSelectedRange(NSRange(location: gap, length: 0))
        two.setKind(.code(""))
        check("两块之间的空行设成代码块后两块仍分开", md(two), "```sh\na\n```\n\n```py\nb\n```\n")
    }
    // 分隔线后回车得到的是普通空行，不是第二条分隔线；图片占位、提示框标题中间打字不会存出两份
    do {
        func save(_ tv: RichTextView, _ s: String) -> String { MarkdownCodec.serialize(RichBridge.blocks(from: tv.textStorage!), preserving: s) }
        var s = "---\n\n正文\n"
        var tv = makeView(s)
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        tv.insertNewline(nil)
        check("分隔线后回车", save(tv, s).components(separatedBy: "---").count == 2 ? "一条" : save(tv, s), "一条")
        type(tv, "字")
        check("分隔线后回车再打字", save(tv, s), "---\n\n字\n\n正文\n")
        s = "![图](a.png)\n"; tv = makeView(s)
        tv.setSelectedRange(NSRange(location: 3, length: 0)); type(tv, "字")
        check("图片占位中间打字", save(tv, s).components(separatedBy: "![图](a.png)").count == 2 ? "一张" : save(tv, s), "一张")
        s = "> [!TIP]\n> 内容\n"; tv = makeView(s)
        tv.setSelectedRange(NSRange(location: 1, length: 0)); type(tv, "字")
        check("提示框标题中间打字", save(tv, s), "> [!TIP]\n> 字\n> 内容\n")
        tv = makeView(s); tv.setSelectedRange(NSRange(location: 2, length: 0)); type(tv, "尾")
        check("提示框标题后面打字", save(tv, s), "> [!TIP]\n> 尾\n> 内容\n")
        check("提示框保存后仍是提示框", makeView(save(tv, s)).string.hasPrefix("提示\n") ? "是" : makeView(save(tv, s)).string, "是")
        // 全选后改成标题：公式块保持是公式
        s = "正文\n\n$$\nE=mc^2\n$$\n"; tv = makeView(s)
        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length)); tv.setKind(.heading(2))
        check("全选改标题不动公式块", save(tv, s), "## 正文\n\n$$\nE=mc^2\n$$\n")
        s = "![a](x.png)![a](x.png)\n"
        check("相邻两张相同的图仍是两张", save(makeView(s), s), s)
        // 找不到的图片显示占位文字：在占位文字中间按回车，图片不能存成两张
        s = "文字\n\n![图](a.png)\n\n后文\n"; tv = makeView(s)
        tv.setSelectedRange(NSRange(location: 6, length: 0)); tv.insertNewline(nil)
        check("图片占位文字中间回车", save(tv, s).components(separatedBy: "![图](a.png)").count - 1 == 1 ? "一张" : save(tv, s), "一张")
        s = "![a](x.png)\n\n![a](x.png)\n"
        check("两段各一张相同的图仍是两张", save(makeView(s), s), s)
        // 行内代码里一部分加了高亮：仍是一段代码，不能写成 `代``码`
        s = "`代码` 后\n"; tv = makeView(s)
        tv.setSelectedRange(NSRange(location: 0, length: 1)); tv.toggle(.highlight)
        check("行内代码一部分加样式", save(tv, s), s)
        s = "一行<br>两行\n"; tv = makeView(s)
        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length - 1)); tv.toggleInlineCode()
        check("带段内换行的文字改成行内代码", save(tv, s), "`一行`<br>`两行`\n")
        // 跨两格选中后打字：前一格的字不能丢
        s = "| a | b |\n| --- | --- |\n| 1 | 2 |\n"; tv = makeView(s)
        tv.setSelectedRange(NSRange(location: 5, length: 2)); type(tv, "字")
        check("跨格选中后打字", save(tv, s).contains("1") && save(tv, s).contains("字") ? "都在" : save(tv, s), "都在")
    }
    // 页边距：窗口窄时最少留 32；自动时窗口越宽文字栏越宽，但不超过 900；最窄时铺满
    for (m, w, want) in [(PageMargin.auto, 700, 32), (.auto, 1000, 164), (.auto, 1357, 258), (.auto, 1700, 400), (.auto, 2400, 750),
                         (.wide, 1700, 514), (.standard, 1700, 450), (.narrow, 1700, 370), (.none, 1700, 32), (.wide, 500, 32)] as [(PageMargin, CGFloat, CGFloat)] {
        check("页边距 \(m.rawValue) \(Int(w))", "\(Int(m.margin(for: w)))", "\(Int(want))")
    }
    // 双页原文的列表按钮：缩进保留，空行不加标记，勾选状态不丢
    for (name, lines, prefix, numbered, want) in [
        ("加列表", ["a", "", "b"], "- ", false, ["- a", "", "- b"]),
        ("去列表", ["- a", "* b"], "- ", false, ["a", "b"]),
        ("嵌套列表换成编号", ["- a", "  - b"], "", true, ["1. a", "  2. b"]),
        ("待办去标记不管勾没勾", ["- [x] a", "- [ ] b"], "- [ ] ", false, ["a", "b"]),
        ("列表改待办", ["- a", "1. b"], "- [ ] ", false, ["- [ ] a", "- [ ] b"]),
        ("待办改列表", ["- [x] a"], "- ", false, ["- a"]),
        ("空行上加列表", [""], "- ", false, ["- "]),
        ("加引用", ["a", "", "b"], "> ", false, ["> a", "> ", "> b"]),
        ("去引用", ["> a", ">", "> b"], "> ", false, ["a", "", "b"]),
        ("文字里的美元和反斜杠", ["$1 \\n"], "- ", false, ["- $1 \\n"]),
    ] as [(String, [String], String, Bool, [String])] {
        check("原文 \(name)", toggledPrefixLines(lines, prefix: prefix, numbered: numbered).joined(separator: "|"), want.joined(separator: "|"))
    }
    // 有脚注的段落不改就保存：不能多出反斜杠（脚注在单页里显示成上标，不算改过）
    for src in ["见 ~/a/*.md 文件[^1]\n", "网址 https://x.y/z_(1) 说明[^2]\n", "> [!TIP]\n> 用 a*b 和 _ 表示\n"] {
        check("带脚注或提示框不改 \(src.debugDescription)", MarkdownCodec.serialize(RichBridge.blocks(from: makeView(src).textStorage!), preserving: src), src)
    }
    // 空代码块、没写完的代码块：不改就保存，原文不变；文档只有一条分隔线时，在后面打的字不会变成分隔线
    for src in ["```\n```\n", "前\n\n```py\n```\n\n后\n", "```py"] {
        check("空代码块不改 \(src.debugDescription)", MarkdownCodec.serialize(RichBridge.blocks(from: makeView(src).textStorage!), preserving: src), src)
    }
    do {
        let tv = makeView("---")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        type(tv, "字")
        check("分隔线后打字", MarkdownCodec.serialize(RichBridge.blocks(from: tv.textStorage!), preserving: "---").contains("字") ? "在" : "丢了", "在")
    }
    // 在第二个代码块里打字，第一个不受影响
    do {
        let tv = makeView("```sh\na\n```\n\n```py\nb\n```\n")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "b").location + 1, length: 0))
        type(tv, "c")
        check("改相邻代码块的第二个", md(tv), "```sh\na\n```\n\n```py\nbc\n```\n")
    }
    // 内嵌图片要显示出来；解不开时不能把整串编码当文字显示
    do {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        check("内嵌图片显示", makeView("![](data:image/png;base64,\(png))\n").textStorage!.containsAttachments ? "图片" : "文字", "图片")
        let bad = makeView("![](data:image/png;base64,AAAA\(String(repeating: "A", count: 4000)))\n")
        check("坏的内嵌图片不显示编码", bad.string.count < 100 ? "短" : "长 \(bad.string.count)", "短")
    }
    // 在段首打一个字：这段会重写，但文字里的网址、路径、符号都不能多出反斜杠或变样
    for line in [
        "见 https://example.com/a_b_c?x=1&y=2#top 页", "变量 my_var_name", "路径 C:\\Users\\a 和 ~/Documents/*.md",
        "邮箱 a_b@example.com", "算式 2*3*4 和 a*b", "比较 a < b > c", "实体 &nbsp; 和 &amp;", "按 <kbd>⌘</kbd> 键",
        "脚注[^1]", "正文 **粗体**、*斜体*、`代码`", "正文**“重点”**内容", "链接 [文字](https://example.com/a_(b))", "图 ![说明](a b.png)",
        "反引号 `a`b` 里", "井号 #标签 和 C#", "百分号 100% 和 $5", "下划线 _ 单独", "竖线 a|b", "波浪 ~ 单独和 ~~删~~",
        "== 不是高亮", "第 1. 条", "中文，标点：“引号”（括号）", "维基 [词条](https://en.wikipedia.org/wiki/Foo_(bar))", "emoji 🎉 和 :tada:",
    ] {
        let src = "第一段\n\n" + line + "\n"
        let tv = makeView(src)
        tv.setSelectedRange(NSRange(location: 4, length: 0))
        type(tv, "字")
        check("段首改字 \(line)", MarkdownCodec.serialize(RichBridge.blocks(from: tv.textStorage!), preserving: src), "第一段\n\n字" + line + "\n")
    }
    // 段落样式：改成各种样式，存出来的写法对；再改回正文，和原来一样
    for (kind, want) in [(RichKind.heading(2), "## 甲乙\n\n丙\n"), (.quote, "> 甲乙\n\n丙\n"), (.bullet(0), "- 甲乙\n\n丙\n"),
                         (.ordered(0), "1. 甲乙\n\n丙\n"), (.task(0, false), "- [ ] 甲乙\n\n丙\n"), (.code(""), "```\n甲乙\n```\n\n丙\n")] {
        let tv = makeView("甲乙\n\n丙\n")
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        tv.setKind(kind)
        check("设为 \(kind)", md(tv), want)
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        tv.setKind(.body)
        check("\(kind) 改回正文", md(tv), "甲乙\n\n丙\n")
    }
    // 选中两段一起改：两段都变，列表连在一起
    do {
        let tv = makeView("甲\n\n乙\n")
        tv.setSelectedRange(NSRange(location: 0, length: 3))
        tv.setKind(.bullet(0))
        check("两段设为列表", md(tv), "- 甲\n- 乙\n")
        tv.setSelectedRange(NSRange(location: 0, length: 3))
        tv.setKind(.code("py"))
        check("两段设为代码块", md(tv), "```py\n甲\n乙\n```\n")
    }
    // 文字格式：加上再去掉，回到原样
    for (trait, want) in [(RichTrait.bold, "甲**乙**丙\n"), (.italic, "甲*乙*丙\n"), (.strike, "甲~~乙~~丙\n"), (.highlight, "甲==乙==丙\n"),
                          (.underline, "甲<u>乙</u>丙\n"), (.sup, "甲<sup>乙</sup>丙\n"), (.sub, "甲<sub>乙</sub>丙\n"), (.kbd, "甲<kbd>乙</kbd>丙\n")] {
        let tv = makeView("甲乙丙\n")
        tv.setSelectedRange(NSRange(location: 1, length: 1))
        tv.toggle(trait)
        check("加 \(trait)", md(tv), want)
        tv.setSelectedRange(NSRange(location: 1, length: 1))
        tv.toggle(trait)
        check("去 \(trait)", md(tv), "甲乙丙\n")
    }
    do {
        let tv = makeView("甲乙丙\n")
        tv.setSelectedRange(NSRange(location: 1, length: 1))
        tv.toggleInlineCode()
        check("加行内代码", md(tv), "甲`乙`丙\n")
        tv.setSelectedRange(NSRange(location: 1, length: 1))
        tv.toggleInlineCode()
        check("去行内代码", md(tv), "甲乙丙\n")
        tv.setSelectedRange(NSRange(location: 1, length: 1))
        tv.setLink("https://example.com/a_(b)")
        check("加链接", md(tv), "甲[乙](https://example.com/a_(b))丙\n")
        tv.setSelectedRange(NSRange(location: 1, length: 1))
        tv.setLink(nil)
        check("去链接", md(tv), "甲乙丙\n")
        // 粗体里再加斜体，再去掉粗体
        tv.setSelectedRange(NSRange(location: 0, length: 3))
        tv.toggle(.bold)
        tv.setSelectedRange(NSRange(location: 1, length: 1))
        tv.toggle(.italic)
        check("粗体里加斜体", md(tv), "**甲*乙*丙**\n")
        tv.setSelectedRange(NSRange(location: 0, length: 3))
        tv.toggle(.bold)
        check("再去掉粗体", md(tv), "甲*乙*丙\n")
    }
    // 列表缩进：加一层、减一层
    do {
        let tv = makeView("- 甲\n- 乙\n")
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        tv.changeDepth(1)
        check("缩进一层", md(tv), "- 甲\n  - 乙\n")
        tv.changeDepth(-1)
        check("减一层", md(tv), "- 甲\n- 乙\n")
        tv.changeDepth(-1)
        check("再减就成正文", md(tv), "- 甲\n\n乙\n")
    }
    // 改别的地方再保存，[[双链]] 不变；在单页里直接打出来的也不转义
    do {
        let tv = makeView("第一行\n\n见 [[读书会]]\n")
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        type(tv, "改")
        check("改别处后双链不变", md(tv), "第一行改\n\n见 [[读书会]]\n")
        let tv2 = makeView("见\n")
        tv2.setSelectedRange(NSRange(location: 1, length: 0))
        type(tv2, " [[新链]]")
        check("打出来的双链", md(tv2), "见 [[新链]]\n")
    }
    // 列表项里的代码块：在里面打字、回车后，保存时仍缩进在列表项下面
    do {
        let tv = makeView("1. 安装：\n\n   ```bash\n   npm i\n   ```\n\n2. 运行\n")
        let end = (tv.string as NSString).range(of: "npm i").upperBound
        tv.setSelectedRange(NSRange(location: end, length: 0))
        type(tv, " -g"); tv.insertNewline(nil); type(tv, "npm run")
        check("列表项里的代码块里打字", md(tv), "1. 安装：\n\n   ```bash\n   npm i -g\n   npm run\n   ```\n\n2. 运行\n")
    }
    // 单个换行显示为空格；在它后面输入的空格还是空格
    do {
        let tv = makeView("一\n二\n")
        check("换行显示为空格", tv.string, "一 二\n")
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        tv.typingAttributes = tv.textStorage!.attributes(at: 1, effectiveRange: nil)
        type(tv, " 加")
        check("换行后输入空格", md(tv), "一\n 加二\n")
    }
    // 脚注：正文里的编号是上标，文末说明行开头的编号不是
    do {
        let tv = makeView("正文[^1]\n\n[^1]: 说明\n")
        let s = tv.textStorage!, ns = tv.string as NSString
        let sup = { (loc: Int) in (s.attribute(.superscript, at: loc, effectiveRange: nil) as? Int) ?? 0 }
        check("脚注引用上标", "\(sup(2))", "1")
        check("脚注说明不上标", "\(sup(ns.range(of: "[^1]", options: .backwards).location))", "0")
        check("脚注往返", md(tv), "正文[^1]\n\n[^1]: 说明\n")
    }
    // 文档语言：自动判断；换成该语言的字体（正文换字体，等宽字体缺字时用该语言的字体）
    do {
        check("语言 日语", DocLanguage.detect("今日は晴れ").rawValue, "ja")
        check("语言 韩语", DocLanguage.detect("한국어 문서").rawValue, "ko")
        check("语言 中文里的・不算日语", DocLanguage.detect("汉字・中文").rawValue == "ja" ? "ja" : "zh", "zh")
        let tv = makeView("**今日**は晴れ `漢字`\n")
        let fixer = LanguageFontFixer()
        fixer.language = .ja
        fixer.apply(to: tv.textStorage!)
        let s = tv.textStorage!
        let body = s.attribute(.font, at: 3, effectiveRange: nil) as! NSFont
        let bold = s.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        let code = s.attribute(.font, at: (tv.string as NSString).range(of: "漢").location, effectiveRange: nil) as! NSFont
        check("日语正文字体", body.familyName ?? "", "Hiragino Sans")
        check("日语粗体", "\(bold.familyName ?? "") \(bold.fontDescriptor.symbolicTraits.contains(.bold))", "Hiragino Sans true")
        // 等宽字体没有汉字：系统改用后备字体，后备字体应是冠群（日文写法）
        check("日语代码里的汉字", (code.familyName ?? "").contains("Hiragino") ? "冠群" : code.familyName ?? "", "冠群")
        fixer.language = .zhCN
        fixer.apply(to: s)
        let zhCode = s.attribute(.font, at: (tv.string as NSString).range(of: "漢").location, effectiveRange: nil) as! NSFont
        // 这台电脑装了（或这次运行注册了）MiSans 时用 MiSans，否则退回苹方
        let hasMiSans = NSFont(name: "MiSans-Regular", size: 12) != nil
        check("简体代码里的汉字", (zhCode.familyName ?? "").contains("PingFang") ? "苹方" : zhCode.familyName ?? "", hasMiSans ? "MiSans" : "苹方")
        check("简体正文字体", (s.attribute(.font, at: 3, effectiveRange: nil) as! NSFont).familyName ?? "", hasMiSans ? "MiSans" : "PingFang SC")
        check("换字体后保存不变", md(tv), "**今日**は晴れ `漢字`\n")
    }
    // 有 MiSans（tools/fetch_fonts.sh 下载过）时：简体、繁体换成 MiSans，粗体用 MiSans 粗体；日语仍用冠群
    if let files = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "build/fonts"), includingPropertiesForKeys: nil),
       !files.isEmpty {
        CTFontManagerRegisterFontURLs(files as CFArray, .process, true, nil)
        let tv = makeView("**今日**中文\n")
        let fixer = LanguageFontFixer()
        func fonts() -> String {
            let s = tv.textStorage!
            return ["\((s.attribute(.font, at: 3, effectiveRange: nil) as! NSFont).fontName)",
                    "\((s.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).fontName)"].joined(separator: " ")
        }
        fixer.language = .zhCN; fixer.apply(to: tv.textStorage!)
        check("简体用 MiSans", fonts(), "MiSans-Regular MiSans-Bold")
        fixer.language = .zhTW; fixer.apply(to: tv.textStorage!)
        check("繁体用 MiSans TC", fonts(), "MiSansTC MiSansTC-Bold")
        fixer.language = .ja; fixer.apply(to: tv.textStorage!)
        check("日语不用 MiSans", fonts().hasPrefix("HiraginoSans") ? "冠群" : fonts(), "冠群")
        check("MiSans 往返不变", md(tv), "**今日**中文\n")
    } else {
        print("跳过 MiSans 测试（没有 build/fonts，先运行 tools/fetch_fonts.sh）")
    }
    // 按文件记住的语言：有记录用记录；没有记录（第一次保存、改名）时保留当前选择
    do {
        check("记住的语言", DocLanguage.forPath("/a.md", current: .auto, saved: ["/a.md": "ja"]).rawValue, "ja")
        check("新路径保留选择", DocLanguage.forPath("/b.md", current: .ko, saved: ["/a.md": "ja"]).rawValue, "ko")
        check("旧选项失效时保留选择", DocLanguage.forPath("/a.md", current: .auto, saved: ["/a.md": "zh-SG"]).rawValue, "auto")
    }
    // 空列表项回车结束列表
    do {
        let tv = makeView("")
        type(tv, "- a"); tv.insertNewline(nil); tv.insertNewline(nil); type(tv, "b")
        check("空列表项回车", md(tv), "- a\n\nb\n")
    }
    // 空待办回车结束待办，之后的自动格式照常生效
    do {
        let tv = makeView("")
        type(tv, "[] a"); tv.insertNewline(nil); tv.insertNewline(nil); type(tv, "> b")
        check("空待办回车", md(tv), "- [ ] a\n\n> b\n")
    }
    // 待办回车后新的一项未勾选
    do {
        let tv = makeView("- [x] a\n")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length - 1, length: 0))
        tv.insertNewline(nil); type(tv, "b")
        check("待办回车", md(tv), "- [x] a\n- [ ] b\n")
    }
    // 表格最后一格按 Tab 增加一行，回车移到下一格
    do {
        let tv = makeView("| A | B |\n|---|---|\n| 1 | 2 |\n")
        let r = (tv.string as NSString).range(of: "2")
        tv.setSelectedRange(NSRange(location: NSMaxRange(r), length: 0))
        tv.insertTab(nil); type(tv, "3"); tv.insertNewline(nil); type(tv, "4")
        check("表格 Tab/回车", md(tv), "| A | B |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |\n")
    }
    // 折叠块：标题后回车进入内容，内容空行回车离开
    do {
        let tv = makeView("<details>\n<summary>标题</summary>\n\n</details>\n")
        let ns = tv.string as NSString
        let r = ns.range(of: "标题")
        tv.setSelectedRange(NSRange(location: NSMaxRange(r), length: 0))
        tv.insertNewline(nil); type(tv, "内容"); tv.insertNewline(nil); tv.insertNewline(nil); type(tv, "外面")
        check("折叠块回车", md(tv), "<details>\n<summary>标题</summary>\n\n内容\n\n</details>\n\n外面\n")
    }
    // 折叠块：打开时 <details> 收起、<details open> 展开；收起不影响保存；光标进入时展开
    do {
        let tv = makeView("<details>\n<summary>标题</summary>\n\n内容\n\n</details>\n\n后面\n")
        let lm = tv.layoutManager as! RichLayoutManager
        lm.ensureLayout(for: tv.textContainer!)
        let body = (tv.string as NSString).range(of: "内容")
        let lineY = { (s: String) in lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: (tv.string as NSString).range(of: s).location), effectiveRange: nil) }
        // 收起的内容不占位置：“后面”紧接在标题这一行下面
        check("折叠块默认收起", "\(lm.hiddenRanges.count) \(lineY("后面").minY == lineY("标题").maxY)", "1 true")
        check("收起时保存不变", md(tv), "<details>\n<summary>标题</summary>\n\n内容\n\n</details>\n\n后面\n")
        tv.setSelectedRange(NSRange(location: body.location + 1, length: 0))
        lm.ensureLayout(for: tv.textContainer!)
        check("光标进入时展开", "\(lm.hiddenRanges.count) \(lineY("内容").minY >= lineY("标题").maxY)", "0 true")
        let title = (tv.string as NSString).range(of: "标题")
        tv.setCollapsed(true, summary: (tv.string as NSString).paragraphRange(for: title))
        check("收起时光标移到标题末尾", "\(lm.hiddenRanges.count) \(tv.selectedRange().location)", "1 \(NSMaxRange(title))")
        type(tv, "二")
        check("收起后在标题输入", md(tv), "<details>\n<summary>标题二</summary>\n\n内容\n\n</details>\n\n后面\n")
    }
    do {
        let src = "<details>\n<summary>标题</summary>\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n</details>\n"
        check("折叠块以表格结尾", md(makeView(src)), src)
    }
    // 公式：单页中显示为一个公式（一个字符），保存时写回原文；双击可修改
    do {
        let src = "公式 $E=mc^2$ 和 $a$$b$ 与金额 \\$5\n\n$$\n\\sum_{i=1}^n i\n$$\n\n后面\n"
        let tv = makeView(src)
        check("公式保存不变", md(tv), src)
        check("公式显示为一个字符", "\(tv.string.filter { $0 == "\u{FFFC}" }.count)", "4")
        tv.editMath = { _ in "$x^2$" }
        tv.editMath(at: (tv.string as NSString).range(of: "\u{FFFC}"))
        check("修改行内公式", md(tv), src.replacingOccurrences(of: "$E=mc^2$", with: "$x^2$"))
        let block = (tv.string as NSString).range(of: "\u{FFFC}", options: .backwards)
        tv.editMath = { _ in "$$\ny\n$$" }
        tv.editMath(at: block)
        check("修改公式块", md(tv), src.replacingOccurrences(of: "$E=mc^2$", with: "$x^2$").replacingOccurrences(of: "\\sum_{i=1}^n i", with: "y"))
    }
    // 从文本编辑、网页粘贴：链接保留地址，系统列表变成单页的列表，颜色去掉；表格里的“1⇥张三”不当成列表
    do {
        let tv = makeView("")
        let pasted = NSMutableAttributedString()
        let font = NSFont(name: "Georgia", size: 20) ?? .systemFont(ofSize: 20)
        pasted.append(NSAttributedString(string: "见", attributes: [.font: font, .foregroundColor: NSColor.red]))
        pasted.append(NSAttributedString(string: "链接", attributes: [.font: font, .link: URL(string: "https://example.com")!,
                                                                    .underlineStyle: NSUnderlineStyle.single.rawValue]))
        pasted.append(NSAttributedString(string: "。\n", attributes: [.font: font]))
        // 列表符号由系统写进 RTF（和文本编辑复制出来的一样）
        func listPara(_ text: String, _ format: NSTextList.MarkerFormat, _ lists: Int) -> NSAttributedString {
            let p = NSMutableParagraphStyle()
            p.textLists = Array(repeating: NSTextList(markerFormat: format, options: 0), count: lists)
            return NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: p])
        }
        pasted.append(listPara("列表一\n", .disc, 1))
        pasted.append(listPara("子项\n", .circle, 2))
        pasted.append(listPara("第一步\n", .decimal, 1))
        pasted.append(NSAttributedString(string: "1\t张三\n", attributes: [.font: font]))
        // 走真正的读取剪贴板流程（粘贴、拖入都走这里），用单独的剪贴板，不影响系统剪贴板
        let board = NSPasteboard(name: NSPasteboard.Name("DropMDTest3-\(ProcessInfo.processInfo.processIdentifier)"))
        board.clearContents()
        board.setData(try! pasted.data(from: NSRange(location: 0, length: pasted.length),
                                       documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]), forType: .rtf)
        _ = tv.readSelection(from: board)
        board.releaseGlobally()
        check("粘贴富文本", md(tv), "见[链接](https://example.com)。\n\n- 列表一\n  - 子项\n\n1. 第一步\n\n1\t张三\n")
    }
    // 从网页、Word 粘贴：RTF 里丢掉的中文斜体和标题，从同时放在剪贴板里的 HTML 补回来
    do {
        @MainActor func paste(rtf text: String, html: String, into src: String = "\n", at location: Int = 0) -> String {
            let tv = makeView(src)
            tv.setSelectedRange(NSRange(location: location, length: 0))
            let s = NSAttributedString(string: text, attributes: [.font: NSFont(name: "PingFangSC-Regular", size: 14)!])
            let board = NSPasteboard(name: NSPasteboard.Name("DropMDTest4-\(ProcessInfo.processInfo.processIdentifier)"))
            board.clearContents()
            board.setData(try! s.data(from: NSRange(location: 0, length: s.length),
                                      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]), forType: .rtf)
            board.setString(html, forType: .html)
            _ = tv.readSelection(from: board)
            board.releaseGlobally()
            return md(tv)
        }
        check("粘贴网页：标题和中文斜体",
              paste(rtf: "大标题\n斜体和斜体\n小标题\n后面\n",
                    html: "<meta charset=utf-8><style>h1{color:red}</style><h1 class=a>大标题</h1>\n<p>斜体和<em>斜体</em></p><h2>小<b>标</b>题</h2><p>后面</p>"),
              "# 大标题\n\n斜体和*斜体*\n\n## 小标题\n\n后面\n")
        check("粘贴网页：样式里的斜体、Word 的假斜体、实体",
              paste(rtf: "甲 & 乙 丙\n", html: "<p><span style=\"font-style: italic\">甲 &amp; 乙</span> <span style='mso-bidi-font-style:italic'>丙</span></p>"),
              "*甲 & 乙* 丙\n")
        check("粘贴网页：中文粗体，Google 文档的假粗体",
              paste(rtf: "甲乙丙丁\n", html: "<b style=\"font-weight:normal\"><p>甲<strong>乙</strong><span style=\"font-weight:700\">丙</span>丁</p></b>"),
              "甲**乙丙**丁\n")
        check("标题粘贴到一行中间不改这一行",
              paste(rtf: "标题", html: "<h1>标题</h1>", into: "前后\n", at: 1), "前标题后\n")
        check("对不上的文字不标斜体", paste(rtf: "正文\n", html: "<p><i>别的</i></p>"), "正文\n")
    }
    // 复制粘贴公式（用单独的剪贴板，不影响系统剪贴板）
    do {
        let tv = makeView("甲 $x^2$ 乙\n")
        let board = NSPasteboard(name: NSPasteboard.Name("DropMDTest-\(ProcessInfo.processInfo.processIdentifier)"))
        tv.setSelectedRange(NSRange(location: 0, length: 4))
        board.clearContents()
        _ = tv.writeSelection(to: board, types: tv.writablePasteboardTypes)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length - 1, length: 0))
        _ = tv.readSelection(from: board)
        board.releaseGlobally()
        check("复制粘贴公式", md(tv), "甲 $x^2$ 乙甲 $x^2$\n")
    }
    do {
        let src = "# 标题\n\n- 列表 **粗** [链接](https://example.com)\n\n![图](no-such.png)\n\n---\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n<details>\n<summary>折叠</summary>\n\n内容\n\n</details>\n\n$$\nx\n$$\n"
        let from = makeView(src), to = makeView("")
        let board = NSPasteboard(name: NSPasteboard.Name("DropMDTest2-\(ProcessInfo.processInfo.processIdentifier)"))
        from.setSelectedRange(NSRange(location: 0, length: (from.string as NSString).length))
        board.clearContents()
        _ = from.writeSelection(to: board, types: from.writablePasteboardTypes)
        _ = to.readSelection(from: board)
        board.releaseGlobally()
        check("整篇复制粘贴", md(to), src)
    }
    // 双击公式：修改
    do {
        let tv = makeView("甲 $x^2$ 乙\n")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = tv
        let lm = tv.layoutManager!
        lm.ensureLayout(for: tv.textContainer!)
        let r = lm.boundingRect(forGlyphRange: NSRange(location: 2, length: 1), in: tv.textContainer!)
        let p = tv.convert(NSPoint(x: tv.textContainerOrigin.x + r.midX, y: tv.textContainerOrigin.y + r.midY), to: nil)
        var asked = ""
        tv.editMath = { s in asked = s; return "$y$" }
        tv.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!)
        check("双击公式修改", asked + " → " + md(tv), "$x^2$ → 甲 $y$ 乙\n")
    }
    do {
        let tv = makeView("前\n")
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        tv.insertInlineMath("x+1")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.insertMathBlock("z")
        check("插入公式", md(tv), "前$x+1$\n\n$$\nz\n$$\n")
    }
    // 单页表示不了的写法：载入后直接保存，内容不变
    for src in ["---\ntitle: 测试\n---\n\n<!-- 注释 -->\n\n正文\n", "5. 五\n6. 六\n\n正文\n\n2. 二\n",
                "> - 列表\n>   - 嵌套\n", "- 一\n\n  续段\n- 二\n", "见[说明][1]。\n\n[1]: https://example.com\n",
                "| 左 | 中 | 右 |\n| :-- | :-: | --: |\n| 1 | 2 | 3 |\n"] {
        check("单页原样保存 \(src.prefix(8).debugDescription)", md(makeView(src)), src)
    }
    // 导出 HTML：本机图片嵌进文件；网络图片、找不到的图片保持原样
    do {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dropmd-export-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("图 片"), withIntermediateDirectories: true)
        try? Data("hi".utf8).write(to: dir.appendingPathComponent("图 片/a.png"))
        let html = #"<p><img src="%E5%9B%BE%20%E7%89%87/a.png" alt="a"><img src="https://example.com/b.png" alt=""><img src="no.png" alt=""><img width="200" src="%E5%9B%BE%20%E7%89%87/a.png"></p>"#
        check("导出 HTML 嵌入图片", HTMLExport.embedLocalImages(html, base: dir),
              #"<p><img src="data:image/png;base64,aGk=" alt="a"><img src="https://example.com/b.png" alt=""><img src="no.png" alt=""><img width="200" src="data:image/png;base64,aGk="></p>"#)
        // 未保存的文档：插入的图片是绝对路径（网页里会被编码）
        let abs = URL(fileURLWithPath: dir.appendingPathComponent("图 片/a.png").path).absoluteString.dropFirst("file://".count)
        check("未保存文档导出 HTML 嵌入本机图片", HTMLExport.embedLocalImages("<img src=\"\(abs)\">", base: nil),
              "<img src=\"data:image/png;base64,aGk=\">")
        // 快速查看：图片换成扩展提供的地址，大图缩小，小图不变；导出时大图保持原图
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2400, pixelsHigh: 1200, bitsPerSample: 8, samplesPerPixel: 3,
                                   hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 7200, bitsPerPixel: 24)!
        arc4random_buf(rep.bitmapData!, 7200 * 1200)   // 随机内容压不小，文件超过 512 KB
        let big = rep.representation(using: .png, properties: [:])!
        try? big.write(to: dir.appendingPathComponent("big.png"))
        let tag = #"<img src="big.png">"#
        let shrunk = HTMLExport.previewImage(dir.appendingPathComponent("big.png"), maxPixel: 1600)
        let shown = shrunk.flatMap { NSBitmapImageRep(data: $0.data) }
        check("快速查看缩小大图", "\(shrunk?.mime ?? "") \(shown?.pixelsWide ?? 0)×\(shown?.pixelsHigh ?? 0)", "image/jpeg 1600×800")
        check("快速查看不动小图", HTMLExport.previewImage(dir.appendingPathComponent("图 片/a.png"), maxPixel: 1600)?.data == Data("hi".utf8) ? "同" : "变了", "同")
        let linked = HTMLExport.linkLocalImages(html, base: dir, scheme: "dropmd-image")
        check("快速查看的图片地址", linked.html,
              #"<p><img loading="lazy" decoding="async" src="dropmd-image:/2" alt="a"><img loading="lazy" decoding="async" src="https://example.com/b.png" alt=""><img loading="lazy" decoding="async" src="dropmd-image:/1" alt=""><img loading="lazy" decoding="async" width="200" src="dropmd-image:/0"></p>"#)
        check("快速查看只读文档写到的图片", linked.images.map(\.lastPathComponent).joined(separator: " "), "a.png no.png a.png")
        check("快速查看图片地址带版本", HTMLExport.linkLocalImages("<img src=\"no.png\">", base: dir, scheme: "dropmd-image", version: 3).html,
              #"<img loading="lazy" decoding="async" src="dropmd-image:/3/0">"#)
        check("带版本的地址能读出版本和第几张", URL(string: "dropmd-image:/3/0")!.pathComponents.joined(separator: " "), "/ 3 0")
        check("地址有编码的本机图片能显示", RichBridge.imageString(path: "big%2Epng", alt: "", baseURL: URL(fileURLWithPath: dir.path, isDirectory: true)).attribute(.attachment, at: 0, effectiveRange: nil) != nil ? "有" : "没有", "有")
        check("导出保持原图", HTMLExport.embedLocalImages(tag, base: dir) == "<img src=\"data:image/png;base64,\(big.base64EncodedString())\">" ? "原图" : "变了", "原图")
        check("导出 HTML 支持单引号与大写 img", HTMLExport.embedLocalImages(#"<IMG SRC='%E5%9B%BE%20%E7%89%87/a.png'>"#, base: dir),
              #"<IMG SRC='data:image/png;base64,aGk='>"#)
        check("导出 HTML 支持未编码空格路径", HTMLExport.embedLocalImages(#"<img src="图 片/a.png">"#, base: dir),
              #"<img src="data:image/png;base64,aGk=">"#)
        check("快速查看支持未编码空格路径", HTMLExport.linkLocalImages(#"<img src="图 片/a.png">"#, base: dir, scheme: "dropmd-image").html,
              #"<img loading="lazy" decoding="async" src="dropmd-image:/0">"#)
        let linkedSingle = HTMLExport.linkLocalImages(#"<IMG SRC='no.png'>"#, base: dir, scheme: "dropmd-image")
        check("快速查看支持单引号与大写 img", "\(linkedSingle.html) \(linkedSingle.images.count)",
              #"<img loading="lazy" decoding="async" SRC='dropmd-image:/0'> 1"#)
        try? FileManager.default.removeItem(at: dir)
    }
    // 光标在公式后（打字属性取自公式这个字符）：输入的文字不能变成公式
    do {
        let tv = makeView("甲 $x^2$\n")
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        tv.typingAttributes = tv.textStorage!.attributes(at: 2, effectiveRange: nil)
        type(tv, "乙")
        check("公式后输入", md(tv), "甲 $x^2$乙\n")
    }
    // 点击标题左边的三角：收起 / 展开；点击标题文字只是放光标
    do {
        let tv = makeView("<details>\n<summary>标题</summary>\n\n内容\n\n</details>\n")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = tv
        let lm = tv.layoutManager as! RichLayoutManager
        lm.ensureLayout(for: tv.textContainer!)
        let line = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let click = { (x: CGFloat) in
            let p = tv.convert(NSPoint(x: tv.textContainerOrigin.x + line.minX + x, y: tv.textContainerOrigin.y + line.midY), to: nil)
            tv.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        click(6)
        check("点击三角展开", "\(lm.hiddenRanges.count)", "0")
        click(6)
        check("再点收起", "\(lm.hiddenRanges.count)", "1")
        check("点三角不改内容", md(tv), "<details>\n<summary>标题</summary>\n\n内容\n\n</details>\n")
    }
    do {
        let tv = makeView("<details open>\n<summary>标题</summary>\n\n内容\n\n</details>\n")
        let lm = tv.layoutManager as! RichLayoutManager
        check("details open 展开并保留", "\(lm.hiddenRanges.count) " + md(tv), "0 <details open>\n<summary>标题</summary>\n\n内容\n\n</details>\n")
    }
    // 标题回车后是正文
    do {
        let tv = makeView("# 标题\n")
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        tv.insertNewline(nil); type(tv, "正文")
        check("标题回车", md(tv), "# 标题\n\n正文\n")
    }
    // 代码块切换：底色清干净，Markdown 正确
    do {
        let tv = makeView("文字\n")
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        tv.setKind(.code(""))
        check("变成代码块", md(tv), "```\n文字\n```\n")
        tv.setKind(.body)
        check("代码块变回正文", md(tv), "文字\n")
        var bg = false
        tv.textStorage!.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: tv.textStorage!.length)) { v, _, _ in if v != nil { bg = true } }
        check("变回正文后无底色", bg ? "有底色" : "无", "无")
    }
    // 列表项中间回车拆成两项
    do {
        let tv = makeView("- 一二\n")
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        tv.insertNewline(nil)
        check("列表项中间回车", md(tv), "- 一\n- 二\n")
    }
    // 退格：列表开头先变回正文；缩进的先减少缩进；待办方框后也算开头
    do {
        let tv = makeView("前\n\n- 项\n")
        let r = (tv.string as NSString).range(of: "项")
        tv.setSelectedRange(NSRange(location: r.location, length: 0))
        tv.deleteBackward(nil)
        check("列表开头退格", md(tv), "前\n\n项\n")
        tv.deleteBackward(nil)
        check("再退格合并", md(tv), "前项\n")
    }
    do {
        let tv = makeView("- 一\n  - 二\n")
        let r = (tv.string as NSString).range(of: "二")
        tv.setSelectedRange(NSRange(location: r.location, length: 0))
        tv.deleteBackward(nil)
        check("缩进列表退格", md(tv), "- 一\n- 二\n")
    }
    do {
        let tv = makeView("- [ ] 待办\n")
        let r = (tv.string as NSString).range(of: "待办")
        tv.setSelectedRange(NSRange(location: r.location, length: 0))
        tv.deleteBackward(nil)
        check("待办开头退格", md(tv), "待办\n")
    }
    do {
        let tv = makeView("正文\n")
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        tv.deleteBackward(nil)
        check("普通退格", md(tv), "正\n")
    }
    // 提示框的竖线颜色：按引用块第一段的标题行判断；普通引用不是提示框
    do {
        let tv = makeView("> [!NOTE]\n> 一\n> 二\n\n> 普通\n")
        let lm = tv.layoutManager as! RichLayoutManager, st = tv.textStorage!, ns = tv.string as NSString
        check("提示框竖线", "\(lm.callout(at: ns.range(of: "二").location, in: st).map { "\($0)" } ?? "无")", "note")
        let plain = makeView("正文\n\n> 普通\n"), plm = plain.layoutManager as! RichLayoutManager
        check("普通引用竖线", "\(plm.callout(at: (plain.string as NSString).range(of: "普通").location, in: plain.textStorage!).map { "\($0)" } ?? "无")", "无")
        for src in ["> [!NOTE]\n> 一\n\n> 普通\n", "> 甲\n\n> 乙\n", "正文\n\n> [!NOTE]\n> 一\n\n> 普通\n"] {
            let t = makeView(src)
            check("两段引用不合并（没改）", MarkdownCodec.serialize(RichBridge.blocks(from: t.textStorage!), preserving: src), src)
            t.setSelectedRange(NSRange(location: (t.string as NSString).length - 1, length: 0)); type(t, "字")
            let want = String(src.dropLast()) + "字\n"
            check("两段引用不合并（改了）", MarkdownCodec.serialize(RichBridge.blocks(from: t.textStorage!), preserving: src), want)
        }
    }
    // 代码块后面多留空：只加在代码块后，没有代码块的文档排版不变
    do {
        for (name, src) in [("代码块后留空", "```\na\n```\n后文\n"), ("网页代码后留空", "<div>\n</div>\n\n后文\n")] {
            let tv = makeView(src), lm = tv.layoutManager as! RichLayoutManager
            let end = lm.glyphIndexForCharacter(at: (tv.string as NSString).range(of: "后文").location - 1)
            check(name, "\(lm.layoutManager(lm, paragraphSpacingAfterGlyphAt: end, withProposedLineFragmentRect: .zero))", "18.0")
        }
        // 表格、列表、折叠块后面的文字和上面留出空隙
        for (name, src, anchor) in [("表格后留空", "| a | b |\n| --- | --- |\n| 1 | 2 |\n\n后文\n", "后文"),
                                     ("折叠块后留空", "<details>\n<summary>折叠</summary>\n\n内容\n\n</details>\n\n后文\n", "后文")] {
            let tv = makeView(src), lm = tv.layoutManager as! RichLayoutManager
            let g = lm.glyphIndexForCharacter(at: (tv.string as NSString).range(of: anchor).location)
            check(name, lm.layoutManager(lm, paragraphSpacingBeforeGlyphAt: g, withProposedLineFragmentRect: .zero) > 0 ? "有" : "无", "有")
        }
        let list = makeView("- 一\n- 二\n\n后文\n"), llm = list.layoutManager as! RichLayoutManager
        let last = llm.glyphIndexForCharacter(at: (list.string as NSString).range(of: "后文").location - 1)
        check("列表结束后留空", llm.layoutManager(llm, paragraphSpacingAfterGlyphAt: last, withProposedLineFragmentRect: .zero) > 5 ? "有" : "无", "有")
        let body = makeView("一\n\n后文\n"), blm = body.layoutManager as! RichLayoutManager
        check("正文段后不变", "\(blm.layoutManager(blm, paragraphSpacingAfterGlyphAt: 1, withProposedLineFragmentRect: .zero))", "8.0")
        let tv = makeView("```\na\nb\n```\n后文\n")
        let lm = tv.layoutManager as! RichLayoutManager
        check("复制的代码块", lm.codeBlock(at: 0).map { (tv.string as NSString).substring(with: $0) } ?? "无", "a\nb\n")
        check("正文不是代码块", lm.codeBlock(at: (tv.string as NSString).range(of: "后文").location) == nil ? "不是" : "是", "不是")
    }
    // 在“不是正文的东西”里打字、退格、回车：屏幕上看到的要和保存后重新打开的一样（随机编辑测试找到的）
    do {
        @MainActor func reopen(_ tv: RichTextView, _ src: String) -> String {
            makeView(MarkdownCodec.serialize(RichBridge.blocks(from: tv.textStorage!), preserving: src)).string
        }
        let cases: [(String, String, String, (RichTextView) -> Void)] = [
            ("占位文字中间打字", "![图](missing.png)\n", "片", { type($0, "字") }),
            ("占位文字中间退格", "![图](missing.png)\n", "片", { $0.deleteBackward(nil) }),
            ("占位文字中间回车", "前 ![图](no.png) 后\n", "片", { $0.insertNewline(nil) }),
            ("提示框标题中间打字", "> [!TIP]\n> 内容\n", "示", { type($0, "字") }),
            ("提示框标题中间退格", "> [!TIP]\n> 内容\n", "示", { $0.deleteBackward(nil) }),
            ("待办方框前打字", "- [ ] 待办\n", "☐", { type($0, "字") }),
        ]
        for (name, src, anchor, op) in cases {
            let tv = makeView(src)
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: anchor).location, length: 0))
            op(tv)
            // 只比文字：行首空格、空文档的空行保存时本来就会整理
            check(name, reopen(tv, src).filter { !$0.isWhitespace }, tv.string.filter { !$0.isWhitespace })
        }
    }
    // 文件被别的程序删掉（Edge 删除下载记录）：监视收到通知；改过才写回，没改过不写回，系统保存时替换文件不算
    do {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dropmd-watch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.md")
        try? Data("原文".utf8).write(to: file)
        var fired = false
        let watch = FileDeletionWatch(url: file) { fired = true }
        try? FileManager.default.removeItem(at: file)
        let until = Date().addingTimeInterval(3)
        while !fired && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        check("文件被删时收到通知", fired ? "收到" : "没收到", "收到")
        _ = watch
        check("改过的文件被删要写回", "\(FileDeletionWatch.shouldWriteBack(fileExists: false, edited: false, text: "原文字", diskText: "原文"))", "true")
        check("没改过的文件被删不写回", "\(FileDeletionWatch.shouldWriteBack(fileExists: false, edited: false, text: "原文", diskText: "原文"))", "false")
        check("系统保存替换文件不写回", "\(FileDeletionWatch.shouldWriteBack(fileExists: true, edited: true, text: "新", diskText: "原文"))", "false")
    }
    // 表格：在两列交界旁 3 点处按下、往右拖 80 点，左列变宽、右列变窄；文字和 Markdown 不变
    do {
        let src = "| 名称 | 说明 |\n| --- | --- |\n| a | b |\n"
        let tv = makeView(src)
        let lm = tv.layoutManager!, storage = tv.textStorage!
        lm.ensureLayout(for: tv.textContainer!)
        let block0 = (storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle).textBlocks.first as! NSTextTableBlock
        let before = block0.value(for: .width)
        let cell0 = lm.boundsRect(for: block0, glyphRange: lm.glyphRange(forCharacterRange: (storage.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0)), actualCharacterRange: nil))
        let y = cell0.midY + tv.textContainerOrigin.y
        let x = cell0.maxX + tv.textContainerOrigin.x
        func send(_ type: NSEvent.EventType, _ px: CGFloat) {
            let p = tv.convert(NSPoint(x: px, y: y), to: nil)
            let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1)!
            switch type {
            case .leftMouseDown: tv.mouseDown(with: e)
            case .leftMouseDragged: tv.mouseDragged(with: e)
            default: tv.mouseUp(with: e)
            }
        }
        send(.leftMouseDown, x + 3); send(.leftMouseDragged, x + 80); send(.leftMouseUp, x + 80)
        let after = block0.value(for: .width)
        check("拖表格列宽：左列变宽", "\(after > before + 5)", "true")
        check("拖表格列宽：两列合计不变", String(format: "%.1f", after + ((storage.attribute(.paragraphStyle, at: (storage.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0)).upperBound, effectiveRange: nil) as! NSParagraphStyle).textBlocks.first as! NSTextTableBlock).value(for: .width)), "100.0")
        check("拖表格列宽：Markdown 不变", md(tv), src)
    }
    // 表格范围：只含表格本身，不含前后的段落
    do {
        let tv = makeView("前文\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n后文\n")
        let storage = tv.textStorage!, ns = storage.string as NSString
        let at = ns.range(of: "1").location
        let r = (tv.layoutManager as! RichLayoutManager).tableRange(around: NSRange(location: at, length: 0), in: storage)
        let text = r.map { ns.substring(with: $0) } ?? ""
        check("表格范围", "\(text.contains("a") && text.contains("2") && !text.contains("前文") && !text.contains("后文"))", "true")
    }
    // 双页：右边单页被点中时，先做完等着的重排（否则在旧内容上打字，左边刚改的字会被冲掉）
    do {
        let tv = makeView("一")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = tv
        var focused = 0
        tv.onFocus = { focused += 1 }
        window.makeFirstResponder(tv)
        check("右边被点中时先重排", "\(focused)", "1")
    }
    // 表格在文末：最后一格按回车、下方向键都跳到表格下面新起一段（以前回车只会加一行，跳不出去）
    for (name, move) in [("回车", { (tv: RichTextView) in tv.insertNewline(nil) }), ("下方向键", { (tv: RichTextView) in tv.moveDown(nil) })] {
        let tv = makeView("| a | b |\n| --- | --- |\n| 1 | 2 |\n")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "2").location, length: 0))
        move(tv); type(tv, "后文")
        check("表格在文末，\(name)跳出表格", md(tv), "| a | b |\n| --- | --- |\n| 1 | 2 |\n\n后文\n")
    }
    // 最后一行的格子里字很长、折成几行：下方向键先走到格子的下一行，不直接跳出表格
    do {
        let tv = makeView("| a | b |\n| --- | --- |\n| 1 | \(String(repeating: "很长的说明文字", count: 30)) |\n\n后文\n")
        tv.layoutManager!.ensureLayout(for: tv.textContainer!)
        let ns = tv.string as NSString
        tv.setSelectedRange(NSRange(location: ns.range(of: "很长").location, length: 0))
        tv.moveDown(nil)
        let at = tv.selectedRange().location
        check("长格子里下方向键先走格子下一行", "\(at < ns.range(of: "后文").location)", "true")
    }
    // 表格后面还有文字：最后一格回车直接移到后面那一段，不新建
    do {
        let tv = makeView("| a |\n| --- |\n| 1 |\n\n后文\n")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "1").location, length: 0))
        tv.insertNewline(nil); type(tv, "X")
        check("表格后有文字，回车移到后文", md(tv), "| a |\n| --- |\n| 1 |\n\nX后文\n")
    }
    // 表格里的退格、向前删（和 Word / Notion 相同：不把两格并在一起、不把别的段落并进表格）
    do {
        let src = "| a | b |\n| --- | --- |\n| 1 | 2 |\n\n后文\n"
        func at(_ tv: RichTextView, _ s: String, end: Bool = false) {
            let r = (tv.string as NSString).range(of: s)
            tv.setSelectedRange(NSRange(location: end ? NSMaxRange(r) : r.location, length: 0))
        }
        var tv = makeView(src)
        at(tv, "2"); tv.deleteBackward(nil); type(tv, "X")
        check("表格：格子开头退格跳到上一格", md(tv), "| a | b |\n| --- | --- |\n| 1X | 2 |\n\n后文\n")
        tv = makeView(src)
        at(tv, "a"); tv.deleteBackward(nil)
        check("表格：第一格开头退格不动", md(tv), src)
        tv = makeView(src)
        at(tv, "后文"); tv.deleteBackward(nil)
        check("表格：下面一段开头退格，先选中整张表", md(tv), src)
        check("表格：选中的是整张表", "\(tv.selectedRange() == (tv.layoutManager as! RichLayoutManager).tableRange(around: NSRange(location: 0, length: 0), in: tv.textStorage!)!)", "true")
        tv.deleteBackward(nil)
        check("表格：再按一下退格删掉整张表", md(tv), "后文\n")
        tv = makeView("| a | b |\n| --- | --- |\n| 1 | 2 |\n")
        at(tv, "2"); tv.moveDown(nil); tv.deleteBackward(nil); tv.deleteBackward(nil)
        check("表格：表格在文末，下面空段按两下退格删掉表格", md(tv), "")
        tv = makeView("前文\n\n|  |  |\n| --- | --- |\n|  |  |\n\n后文\n")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "前文").location + 3, length: 0))
        tv.deleteBackward(nil)
        check("表格：全空表格第一格退格删掉整张表", md(tv), "前文\n\n后文\n")
        tv = makeView(src)
        let ns = tv.string as NSString
        tv.setSelectedRange(NSRange(location: ns.range(of: "b").location, length: ns.range(of: "1").location + 1 - ns.range(of: "b").location))
        tv.deleteBackward(nil)
        check("表格：选中几格退格清空这几格", md(tv), "| a |  |\n| --- | --- |\n|  | 2 |\n\n后文\n")
        tv = makeView(src)
        let ns2 = tv.string as NSString
        tv.setSelectedRange(NSRange(location: ns2.range(of: "2").location, length: ns2.range(of: "文").location - ns2.range(of: "2").location))
        tv.deleteBackward(nil)
        check("表格：选区伸到表格外，整张表删掉", md(tv), "文\n")
        tv = makeView(src)
        at(tv, "1", end: true); tv.deleteForward(nil)
        check("表格：格子末尾向前删不动", md(tv), src)
        tv = makeView("前文\n\n" + src)
        at(tv, "前文", end: true); tv.deleteForward(nil)
        check("表格：上面一段末尾向前删，先选中整张表", md(tv), "前文\n\n" + src)
        tv.deleteForward(nil)
        check("表格：再按一下向前删删掉整张表", md(tv), "前文\n\n后文\n")
        tv = makeView(src)
        let ns3 = tv.string as NSString
        tv.setSelectedRange(NSRange(location: ns3.range(of: "a").location + 1, length: ns3.range(of: "2").location + 1 - ns3.range(of: "a").location - 1))
        tv.deleteBackward(nil)
        check("表格：从第一格拖选到最后一格，退格删掉整张表", md(tv), "后文\n")
        tv = makeView("| a |\n| --- |\n")
        tv.setSelectedRange(NSRange(location: 0, length: 1))
        tv.deleteBackward(nil)
        check("表格：只有一格时选中字只删字", md(tv), "|  |\n| --- |\n")
    }
    // 删行：选中整行按退格；空行第一格按退格
    do {
        let src = "| a | b |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |\n| 5 | 6 |\n\n后文\n"
        @MainActor func sel(_ v: RichTextView, _ from: String, _ to: String) {
            let ns = v.string as NSString
            let a = ns.range(of: from).location, b = NSMaxRange(ns.range(of: to))
            v.setSelectedRange(NSRange(location: a, length: b - a))
        }
        var tv = makeView(src)
        sel(tv, "3", "4"); tv.deleteBackward(nil); type(tv, "X")
        check("表格：选中整行退格删掉这一行", md(tv), "| a | b |\n| --- | --- |\n| 1 | 2 |\n| X5 | 6 |\n\n后文\n")
        tv = makeView(src)
        sel(tv, "1", "4"); tv.deleteBackward(nil)
        check("表格：选中两行退格删掉两行", md(tv), "| a | b |\n| --- | --- |\n| 5 | 6 |\n\n后文\n")
        tv = makeView(src)
        sel(tv, "5", "6"); tv.deleteBackward(nil); type(tv, "X")
        check("表格：删掉最后一行，光标到上一行", md(tv), "| a | b |\n| --- | --- |\n| 1 | 2 |\n| X3 | 4 |\n\n后文\n")
        tv = makeView(src)
        sel(tv, "4", "6"); tv.deleteBackward(nil)
        check("表格：没从第一格选起只清空", md(tv), "| a | b |\n| --- | --- |\n| 1 | 2 |\n| 3 |  |\n|  |  |\n\n后文\n")
        tv = makeView(src)
        sel(tv, "a", "2"); tv.deleteBackward(nil)
        check("表格：选到表头就删整张表", md(tv), "后文\n")
        tv = makeView("| a | b |\n| --- | --- |\n| 1 | 2 |\n|  |  |\n\n后文\n")
        let ns = tv.string as NSString
        tv.setSelectedRange(NSRange(location: NSMaxRange(ns.range(of: "2")) + 1, length: 0))
        tv.deleteBackward(nil); type(tv, "X")
        check("表格：空行第一格退格删掉这一行", md(tv), "| a | b |\n| --- | --- |\n| 1 | 2X |\n\n后文\n")
    }
    // 双页位置标记：表格按格子外框算；侧边线画在文字栏左边；光标画在对应的字前面
    do {
        let tv = makeView("前文\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n后文\n")
        tv.textContainerInset = NSSize(width: 60, height: 20)
        let lm = tv.layoutManager!, c = tv.textContainer!
        lm.ensureLayout(for: c)
        let ns = tv.string as NSString
        let table = (lm as! RichLayoutManager).tableRange(around: ns.range(of: "a"), in: tv.textStorage!)!
        tv.sourceCursorRange = table
        let box = tv.markRect()!
        var cells = NSRect.null
        var i = table.location
        while i < NSMaxRange(table) {
            let para = ns.paragraphRange(for: NSRange(location: i, length: 0))
            let b = (tv.textStorage!.attribute(.paragraphStyle, at: i, effectiveRange: nil) as! NSParagraphStyle).textBlocks.first!
            cells = cells.union(lm.boundsRect(for: b, glyphRange: lm.glyphRange(forCharacterRange: para, actualCharacterRange: nil)))
            i = NSMaxRange(para)
        }
        check("位置标记：表格的框包住整张表", "\(abs(box.minY - (cells.minY + tv.textContainerOrigin.y)) < 0.5 && abs(box.maxY - (cells.maxY + tv.textContainerOrigin.y)) < 0.5)", "true")
        check("位置标记：侧边线在文字栏左边", "\(tv.markBarRect()!.maxX < tv.textContainerOrigin.x)", "true")
        tv.sourceCursorRange = ns.range(of: "后文")
        tv.sourceCaretLocation = ns.range(of: "文").location
        let caret = tv.markCaretRect()!
        let glyph = lm.glyphIndexForCharacter(at: ns.range(of: "文").location)
        let x = lm.location(forGlyphAt: glyph).x + lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX + tv.textContainerOrigin.x
        check("位置标记：光标在对应的字前面", "\(abs(caret.midX - x) < 1.5)", "true")
    }
    // 链接指向哪里：网页、本机 Markdown、其他文件、找不到、不支持、文内跳转
    do {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linktest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "x".write(to: dir.appendingPathComponent("另一篇.md"), atomically: true, encoding: .utf8)
        try? "x".write(to: dir.appendingPathComponent("图 1.png"), atomically: true, encoding: .utf8)
        let base = dir.appendingPathComponent("当前.md")
        func kind(_ t: LinkTarget) -> String {
            switch t { case .web: return "web"; case .markdown: return "md"; case .file: return "file"
            case .missing: return "missing"; case .unsupported: return "unsupported"; case .anchor: return "anchor" }
        }
        check("链接：网页", kind(LinkTarget.resolve("https://example.com", baseURL: base)), "web")
        check("链接：邮件", kind(LinkTarget.resolve("mailto:a@example.com", baseURL: base)), "web")
        check("链接：本机 Markdown", kind(LinkTarget.resolve("另一篇.md", baseURL: base)), "md")
        check("链接：本机其他文件（含空格编码）", kind(LinkTarget.resolve("图%201.png", baseURL: base)), "file")
        check("链接：文件不存在", kind(LinkTarget.resolve("不存在.md", baseURL: base)), "missing")
        check("链接：没保存的文档里的相对路径", kind(LinkTarget.resolve("另一篇.md", baseURL: nil)), "missing")
        check("链接：不支持的写法", kind(LinkTarget.resolve("javascript:alert(1)", baseURL: base)), "unsupported")
        check("链接：文内跳转", kind(LinkTarget.resolve("#标题", baseURL: base)), "anchor")
        check("链接：确认窗口显示文件名", LinkTarget.resolve("另一篇.md", baseURL: base).display, "另一篇.md")
        try? FileManager.default.removeItem(at: dir)
    }
    // 重画碰到表格的一小块时，整张表格一起重画（只画几格时边框会断）
    do {
        let tv = makeView("前文\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n后文\n")
        let lm = tv.layoutManager!, c = tv.textContainer!
        lm.ensureLayout(for: c)
        let ns = tv.string as NSString
        let small = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: ns.range(of: "2"), actualCharacterRange: nil), in: c)
        let table = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: (lm as! RichLayoutManager).tableRange(around: ns.range(of: "a"), in: tv.textStorage!)!, actualCharacterRange: nil), in: c)
        check("表格：重画区域扩大到整张表", "\(tv.rectWithTables(small).contains(table))", "true")
        let text = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: ns.range(of: "后文"), actualCharacterRange: nil), in: c)
        check("表格：表格外的重画区域不变", "\(tv.rectWithTables(text) == text)", "true")
    }
    // 右键菜单：在下方插入一行、删除这一行、删除表格
    do {
        let src = "前文\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |\n\n后文\n"
        var tv = makeView(src)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "1").location, length: 0))
        tv.insertTableRowBelow(nil); type(tv, "新")
        check("表格：在下方插入一行", md(tv), "前文\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n| 新 |  |\n| 3 | 4 |\n\n后文\n")
        tv = makeView(src)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "1").location, length: 0))
        tv.deleteTableRow(nil)
        check("表格：删除这一行", md(tv), "前文\n\n| a | b |\n| --- | --- |\n| 3 | 4 |\n\n后文\n")
        tv = makeView(src)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "a").location, length: 0))
        tv.deleteTableRow(nil)
        check("表格：表头那一行不能删", md(tv), src)
        tv.deleteTable(nil)
        check("表格：删除表格", md(tv), "前文\n\n后文\n")
        @MainActor func at(_ s: String) -> RichTextView {
            let v = makeView(src)
            v.setSelectedRange(NSRange(location: (v.string as NSString).range(of: s).location, length: 0))
            return v
        }
        tv = at("3"); tv.insertTableRowAbove(nil); type(tv, "新")
        check("表格：在上方插入一行", md(tv), "前文\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n| 新 |  |\n| 3 | 4 |\n\n后文\n")
        tv = at("a"); tv.insertTableRowAbove(nil)
        check("表格：表头上方不插行", md(tv), src)
        tv = at("2"); tv.insertTableColumnLeft(nil); type(tv, "左")
        check("表格：在左边插入一列", md(tv), "前文\n\n| a |  | b |\n| --- | --- | --- |\n| 1 | 左 | 2 |\n| 3 |  | 4 |\n\n后文\n")
        tv = at("2"); tv.insertTableColumnRight(nil); type(tv, "右")
        check("表格：在右边插入一列", md(tv), "前文\n\n| a | b |  |\n| --- | --- | --- |\n| 1 | 2 | 右 |\n| 3 | 4 |  |\n\n后文\n")
        tv = at("2"); tv.deleteTableColumn(nil)
        check("表格：删除这一列", md(tv), "前文\n\n| a |\n| --- |\n| 1 |\n| 3 |\n\n后文\n")
        tv.deleteTableColumn(nil)
        check("表格：只剩一列不能删", md(tv), "前文\n\n| a |\n| --- |\n| 1 |\n| 3 |\n\n后文\n")
        tv = at("2")
        let center = NSMenuItem(); center.representedObject = ":-:"
        tv.alignTableColumn(center)
        check("表格：这一列居中", md(tv), "前文\n\n| a | b |\n| --- | :-: |\n| 1 | 2 |\n| 3 | 4 |\n\n后文\n")
        // 在格子里点右键：菜单最上面是表格的操作，当前对齐打勾
        do {
            let v = at("2")
            let window = NSWindow(contentRect: v.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = v
            v.layoutManager!.ensureLayout(for: v.textContainer!)
            let lm = v.layoutManager!
            let r = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: (v.string as NSString).range(of: "2"), actualCharacterRange: nil), in: v.textContainer!)
            let p = v.convert(NSPoint(x: r.midX + v.textContainerOrigin.x, y: r.midY + v.textContainerOrigin.y), to: nil)
            let e = NSEvent.mouseEvent(with: .rightMouseDown, location: p, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            let items = v.menu(for: e)!.items.prefix(12).map { ($0.isSeparatorItem ? "-" : $0.title) + ($0.state == .on ? "✓" : "") }
            check("表格：右键菜单", items.joined(separator: "|"),
                  "在上方插入行|在下方插入行|删除行|-|在左侧插入列|在右侧插入列|删除列|-|对齐方式|复制表格|删除表格|-")
        }
        tv = at("1"); tv.copyTable(nil)
        check("表格：复制表格", NSPasteboard.general.string(forType: .string) ?? "", "| a | b |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |\n")
    }
    // 右键菜单：跟着点中的东西变，放工具栏上没有的操作
    do {
        @MainActor func at(_ src: String, _ s: String, select: Bool = false) -> RichTextView {
            let v = makeView(src)
            let r = (v.string as NSString).range(of: s)
            v.setSelectedRange(select ? r : NSRange(location: r.location, length: 0))
            return v
        }
        @MainActor func titles(_ v: RichTextView, hit: Int? = nil) -> String {
            v.contextItems(hit: hit ?? v.selectedRange().location).map { $0.isSeparatorItem ? "-" : $0.title }.joined(separator: "|")
        }
        func obj(_ o: Any) -> NSMenuItem { let m = NSMenuItem(); m.representedObject = o; return m }
        NSPasteboard.general.clearContents()
        var tv = at("**粗** ~~删~~ `码` [链](https://a.com)\n", "粗", select: true)
        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length - 1))
        check("右键：选中文字有格式项", "\(titles(tv).hasPrefix("删除线|高亮|行内代码|清除格式"))", "true")
        tv.clearFormatting(nil)
        check("右键：清除格式（链接留着）", md(tv), "粗 删 码 [链](https://a.com)\n")
        tv = at("前 [链接](https://a.com) 后\n", "接")
        check("右键：链接上的操作", "\(titles(tv, hit: tv.selectedRange().location).hasPrefix("打开链接|编辑链接…|复制链接|移除链接"))", "true")
        let linkItem = tv.contextItems(hit: tv.selectedRange().location).first { $0.title == "移除链接" }!
        tv.removeLink(linkItem)
        check("右键：去掉链接", md(tv), "前 链接 后\n")
        tv = at("![旧说明](a.png)\n", "旧")
        let img = NSRange(location: 0, length: (tv.string as NSString).length - 1)
        check("右键：图片上的操作", "\(titles(tv, hit: 0).hasPrefix("编辑替代文本…|提取图片中的文字|在访达中显示|删除图片"))", "true")
        tv.setImageAlt("新说明", in: img)
        check("右键：修改图片说明", md(tv), "![新说明](a.png)\n")
        // 正常显示的图片（一个附件字符）也有图片菜单
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("dropmd-menu-\(ProcessInfo.processInfo.processIdentifier).png")
        try? Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!.write(to: png)
        tv = makeView("![图](\(png.path))\n")
        check("右键：显示出来的图片也有图片菜单", "\(titles(tv, hit: 0).hasPrefix("编辑替代文本…|提取图片中的文字|在访达中显示|删除图片"))", "true")
        try? FileManager.default.removeItem(at: png)
        // 列表项开头、表格里的图片改说明：列表、表格还在
        for (src, want) in [("- ![旧](a.png) 后\n", "- ![新](a.png) 后\n"),
                            ("| ![旧](a.png) | b |\n| --- | --- |\n", "| ![新](a.png) | b |\n| --- | --- |\n")] {
            tv = makeView(src)
            let at = (tv.string as NSString).range(of: "\u{FFFC}").location
            tv.setImageAlt("新", in: tv.objectRange(at: at) ?? NSRange(location: at, length: 1))
            check("右键：改说明不破坏 \(src.prefix(2))", md(tv), want)
        }
        // 行内 HTML 图片改说明时保留 width 等属性；整块 raw HTML 图片菜单不提供“编辑替代文本…”和“删除图片”
        tv = makeView("<img src=\"a.png\" width=\"112\" alt=\"旧\">\n")
        tv.setImageAlt("新", in: tv.objectRange(at: 0) ?? NSRange(location: 0, length: 1))
        check("右键：行内 HTML 图片改说明保留宽度", md(tv), "<img src=\"a.png\" width=\"112\" alt=\"新\">\n")
        tv = makeView("<p align=\"center\"><img src=\"a.png\"></p>\n")
        let htmlBlockMenu = titles(tv, hit: 0)
        check("右键：raw HTML 图片隐藏改说明和删除项",
              "\(!htmlBlockMenu.contains("编辑替代文本…") && !htmlBlockMenu.contains("删除图片") && htmlBlockMenu.contains("提取图片中的文字"))", "true")
        tv = at("```swift\nlet a = 1\nlet b = 2\n```\n", "b")
        check("右键：代码块里的操作", "\(titles(tv).hasPrefix("复制代码|语言"))", "true")
        tv.setCodeLanguage(obj("python"))
        check("右键：更改代码语言", md(tv), "```python\nlet a = 1\nlet b = 2\n```\n")
        tv.copyCode(nil)
        check("右键：复制代码", NSPasteboard.general.string(forType: .string) ?? "", "let a = 1\nlet b = 2")
        tv = at("> [!NOTE]\n> 内容\n", "内容")
        check("右键：提示框里的操作", "\(titles(tv).hasPrefix("提示框类型|转换为引用"))", "true")
        tv.setCalloutType(obj(MDCallout.allCases.first { $0 != .note }!.rawValue))
        check("右键：改提示框类型", md(tv), "> \(MDCallout.allCases.first { $0 != .note }!.header)\n> 内容\n")
        type(tv, "X")
        check("右键：改类型后光标还在内容里", "\(md(tv).contains("X内容"))", "true")
        tv = at("> [!NOTE]\n> 内容\n", "内容")
        tv.removeCallout(nil)
        check("右键：改回普通引用", md(tv), "> 内容\n")
        // 折叠块里的表格：最后一格按 Tab 加的行还在折叠块里
        tv = at("<details>\n<summary>折叠</summary>\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n</details>\n", "2 |")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "2").location + 1, length: 0))
        tv.insertTab(nil); type(tv, "3")
        check("折叠块里的表格加行", md(tv), "<details>\n<summary>折叠</summary>\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n| 3 |  |\n\n</details>\n")
        // 折叠块里插入分隔线：折叠块不被截断
        tv = at("<details>\n<summary>折叠</summary>\n\n第一段\n\n第二段\n\n</details>\n", "第一段")
        tv.insertRule()
        check("折叠块里插入分隔线", md(tv), "<details>\n<summary>折叠</summary>\n\n第一段\n\n---\n\n第二段\n\n</details>\n")
        // 列表项里的代码块改语言：还在列表里
        let listCode = "1. 安装：\n\n   ```bash\n   npm i\n   ```\n\n2. 运行\n"
        tv = at(listCode, "npm")
        tv.setCodeLanguage(obj("sh"))
        check("列表里的代码块改语言", md(tv), listCode.replacingOccurrences(of: "bash", with: "sh"))
        // 原样保存的 HTML：没有“语言”菜单
        tv = at("<div>\nhello\n</div>\n", "hello")
        check("HTML 块没有语言菜单", "\(titles(tv).contains("语言"))", "false")
        // 在链接上点右键：只有 DropMD 自己的链接项，系统的那几项去掉；没选字时不出现格式项
        do {
            let v = at("前 [链接](https://a.com) 后\n", "后")
            let window = NSWindow(contentRect: v.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = v
            v.layoutManager!.ensureLayout(for: v.textContainer!)
            let lm = v.layoutManager!
            let r = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: (v.string as NSString).range(of: "链"), actualCharacterRange: nil), in: v.textContainer!)
            let p = v.convert(NSPoint(x: r.midX + v.textContainerOrigin.x, y: r.midY + v.textContainerOrigin.y), to: nil)
            let e = NSEvent.mouseEvent(with: .rightMouseDown, location: p, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            let menu = v.menu(for: e)!
            let names = menu.items.compactMap { $0.action.map { NSStringFromSelector($0) } }
            check("右键：链接上不重复", "\(names.filter { ["openLinkItem:", "_openLinkFromMenu:", "copyLink:", "orderFrontLinkPanel:", "_removeLinkFromMenu:"].contains($0) })", "[\"openLinkItem:\"]")
            check("右键：没选字时没有格式项", "\(names.contains("clearFormatting:"))", "false")
            check("右键：没有字体、快速查看等用不上的系统项", "\(names.contains { $0.hasPrefix("toggleQuickLook") } || menu.items.contains { $0.submenu?.items.contains { $0.action.map { NSStringFromSelector($0).hasPrefix("orderFrontFontPanel") } ?? false } ?? false })", "false")
            check("右键：没有连着的分隔线", "\(zip(menu.items, menu.items.dropFirst()).contains { $0.isSeparatorItem && $1.isSeparatorItem })", "false")
        }
        NSPasteboard.general.clearContents()
        tv = at("- 项目\n", "项目")
        check("右键：列表里有缩进", titles(tv), "增加缩进|减少缩进")
        tv = at("正文\n", "文")
        check("右键：普通段落", titles(tv), "转换为|插入")
    }
    // 单页内复制粘贴、插入图片和脚注：不拆开表格、列表、折叠块
    do {
        @MainActor func at(_ tv: RichTextView, _ s: String) -> NSRange { (tv.string as NSString).range(of: s) }
        @MainActor func copyPaste(_ src: String, copy: String, onto: String) -> String {
            let tv = makeView(src)
            let board = NSPasteboard(name: NSPasteboard.Name("DropMDTest5-\(UUID().uuidString)"))
            tv.setSelectedRange(at(tv, copy))
            board.clearContents()
            _ = tv.writeSelection(to: board, types: tv.writablePasteboardTypes)
            tv.setSelectedRange(at(tv, onto))
            _ = tv.readSelection(from: board)
            board.releaseGlobally()
            return md(tv)
        }
        let table = "一段正文\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n"
        let details = "外部文字\n\n<details>\n<summary>折叠</summary>\n\n第一段\n\n第二段\n\n</details>\n"
        check("正文粘进表格单元格", copyPaste(table, copy: "正文", onto: "1"), "一段正文\n\n| A | B |\n| --- | --- |\n| 正文 | 2 |\n")
        check("单元格文字粘进正文", copyPaste(table, copy: "1", onto: "一段正文"), "1\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n")
        check("折叠块外的文字粘进折叠块", copyPaste(details, copy: "外部文字", onto: "第一段"),
              "外部文字\n\n<details>\n<summary>折叠</summary>\n\n外部文字\n\n第二段\n\n</details>\n")
        check("多段粘进折叠块", copyPaste("甲\n\n乙\n\n" + details.dropFirst(6), copy: "甲\n乙", onto: "第一段"),
              "甲\n\n乙\n\n<details>\n<summary>折叠</summary>\n\n甲\n\n乙\n\n第二段\n\n</details>\n")
        do {
            let tv = makeView(details)
            let board = NSPasteboard(name: NSPasteboard.Name("DropMDTest6-\(UUID().uuidString)"))
            board.clearContents()
            board.setString("新内容", forType: .string)
            tv.setSelectedRange(at(tv, "第一段"))
            _ = tv.readSelection(from: board)
            board.releaseGlobally()
            check("纯文字粘进折叠块", md(tv), "外部文字\n\n<details>\n<summary>折叠</summary>\n\n新内容\n\n第二段\n\n</details>\n")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DropMDTest-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("pic.png").path
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: png))
        for (name, src, spot, image, note) in [
            ("表格", "| A | B |\n| --- | --- |\n| 1 | 2 |\n", "1",
             "| A | B |\n| --- | --- |\n| ![图](P)1 | 2 |\n", "| A | B |\n| --- | --- |\n| [^1]1 | 2 |\n\n[^1]: 说明\n"),
            ("列表", "- 第一项\n", "第一项", "- ![图](P)第一项\n", "- [^1]第一项\n\n[^1]: 说明\n"),
            ("折叠块", details, "第一段",
             "外部文字\n\n<details>\n<summary>折叠</summary>\n\n![图](P)第一段\n\n第二段\n\n</details>\n",
             "外部文字\n\n<details>\n<summary>折叠</summary>\n\n[^1]第一段\n\n第二段\n\n</details>\n\n[^1]: 说明\n"),
        ] {
            var tv = makeView(src)
            tv.setSelectedRange(NSRange(location: at(tv, spot).location, length: 0))
            tv.insertImage(path: png, alt: "图")
            check("插入图片是附件：\(name)", "\(tv.textStorage!.attribute(.attachment, at: at(tv, spot).location - 1, effectiveRange: nil) != nil)", "true")
            check("插入图片：\(name)", md(tv).replacingOccurrences(of: png, with: "P"), image)
            tv = makeView(src)
            tv.setSelectedRange(NSRange(location: at(tv, spot).location, length: 0))
            tv.insertFootnote(label: "1", note: "说明")
            check("插入脚注：\(name)", md(tv), note)
        }
        var tv = makeView("<details open>\n<summary>折叠</summary>\n\n内容\n\n</details>\n")
        tv.setSelectedRange(NSRange(location: at(tv, "折叠").location, length: 0))
        tv.insertRule()
        check("折叠块标题上插入分隔线", md(tv), "<details open>\n<summary>折叠</summary>\n\n---\n\n内容\n\n</details>\n")
        tv = makeView("---\ntitle: Demo\n---\n\n```python\nprint(1)\n```\n")
        let block = (tv.layoutManager as! RichLayoutManager).codeBlock(at: at(tv, "print").location)
        check("复制代码不带 YAML 信息", block.map { (tv.string as NSString).substring(with: $0) } ?? "无", "print(1)\n")
        tv = makeView("```python\nline1\nline2\n```\n")
        tv.setSelectedRange(NSRange(location: at(tv, "line2").location, length: 0))
        tv.setCodeLanguage(to: "swift")
        check("第 2 行换语言：整块换", md(tv), "```swift\nline1\nline2\n```\n")
    }
    // 文档大纲提取：各级标题、闭合 #、行内格式与链接、跳过代码块里的注释
    do {
        let doc = """
        # **总览** [官网](https://example.com)

        ```python
        # 代码里的注释
        ```

        ## `API` 接口 ###

        ~~~bash
        ## 另一个注释
        ~~~

        ### ~~旧~~ ==高亮== __说明__
        """
        let got = extractHeadings(doc)
        let want = [
            DocumentHeading(id: 0, level: 1, title: "总览 官网"),
            DocumentHeading(id: 6, level: 2, title: "API 接口"),
            DocumentHeading(id: 12, level: 3, title: "旧 高亮 说明"),
        ]
        check("大纲提取标题", "\(got)", "\(want)")
        // YAML 信息、HTML 注释里的 # 不算；=== 下划线标题、折叠块里的标题算，行号对得上
        let doc2 = "---\ntitle: Demo\n# 草稿备注\n---\n\n# 正文标题\n\n<!--\n# 注释里的\n-->\n\n下划线标题\n===\n\n<details>\n<summary>折叠</summary>\n\n## 折叠里的\n\n</details>\n"
        check("大纲：跳过 YAML、HTML 注释，认下划线和折叠块", extractHeadings(doc2).map { "\($0.id):\($0.level):\($0.title)" }.joined(separator: " | "),
              "5:1:正文标题 | 11:1:下划线标题 | 17:2:折叠里的")
        // 目录跳转：单页里第 n 个标题与目录第 n 条是同一个；跳进收起的折叠块时展开
        let tv = makeView(doc2)
        // 目录里每一条在单页里都找得到同一个标题
        @MainActor func jumps(_ d: String) -> String {
            let v = makeView(d), list = extractHeadings(d)
            return list.enumerated().map { i, h in
                let k = list.prefix(i).filter { $0.title == h.title }.count
                return v.headingParagraph(title: h.title, occurrence: k).map { (v.string as NSString).substring(with: $0).trimmingCharacters(in: .newlines) } ?? "无"
            }.joined(separator: " | ")
        }
        check("目录每条都跳得到", jumps(doc2), "正文标题 | 下划线标题 | 折叠里的")
        check("目录：只有图片的标题不算", jumps("# ![](a.png)\n\n# 真实标题\n"), "真实标题")
        check("目录：折叠块里的折叠块不往里找", jumps("<details>\n<summary>外层</summary>\n\n<details>\n<summary>内层</summary>\n\n## 内层标题\n\n</details>\n\n</details>\n\n# 后面标题\n"), "后面标题")
        check("目录：折叠块开头的 --- 不是 YAML", jumps("<details>\n<summary>折叠</summary>\n---\n## 两条线中间的标题\n---\n\n</details>\n\n# 后面标题\n"), "两条线中间的标题 | 后面标题")
        check("目录：同名标题按第几个找", jumps("# 小结\n\n正文\n\n# 小结\n"), "小结 | 小结")
        let inside = tv.headingParagraph(title: "折叠里的", occurrence: 0)!
        check("折叠块开始时是收起的", "\((tv.layoutManager as! RichLayoutManager).hiddenRanges.isEmpty)", "false")
        tv.setSelectedRange(NSRange(location: inside.location, length: 0))
        check("跳进收起的折叠块时展开", "\((tv.layoutManager as! RichLayoutManager).hiddenRanges.isEmpty)", "true")
    }
    // YAML 信息、HTML 里按回车只是换行，空行再回车回到正文；公式块后回车是正文
    do {
        let tv = makeView("---\ntitle: Demo\n---\n\n正文\n")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "title: Demo").location + 11, length: 0))
        tv.insertNewline(nil)
        type(tv, "author: Bob")
        check("YAML 里回车", md(tv), "---\ntitle: Demo\nauthor: Bob\n---\n\n正文\n")
        let close = (tv.string as NSString).range(of: "---", options: .backwards, range: NSRange(location: 0, length: (tv.string as NSString).range(of: "正文").location))
        tv.setSelectedRange(NSRange(location: NSMaxRange(close), length: 0))
        tv.insertNewline(nil)
        tv.insertNewline(nil)
        type(tv, "后")
        check("YAML 结尾空行再回车回到正文", md(tv), "---\ntitle: Demo\nauthor: Bob\n---\n\n后\n\n正文\n")
        let t2 = makeView("<div>\n<p>a</p>\n</div>\n\n正文\n")
        t2.setSelectedRange(NSRange(location: (t2.string as NSString).range(of: "<p>a</p>").location + 8, length: 0))
        t2.insertNewline(nil)
        type(t2, "<p>b</p>")
        check("HTML 里回车", md(t2), "<div>\n<p>a</p>\n<p>b</p>\n</div>\n\n正文\n")
        // 块中间的空行再回车：不把块切开，到整块后面开始正文
        @MainActor func exitMiddle(_ src: String, after: String, line: String) -> String {
            let tv = makeView(src)
            tv.setSelectedRange(NSRange(location: NSMaxRange((tv.string as NSString).range(of: after)), length: 0))
            tv.insertNewline(nil)
            type(tv, line)
            tv.insertNewline(nil)
            tv.insertNewline(nil)
            type(tv, "后")
            return md(tv)
        }
        check("YAML 中间空行再回车到整块后面", exitMiddle("---\ntitle: Demo\ntags: a\n---\n\n正文\n", after: "tags: a", line: "new: 1"),
              "---\ntitle: Demo\ntags: a\nnew: 1\n---\n\n后\n\n正文\n")
        check("HTML 中间空行再回车到整块后面", exitMiddle("<div>\nHTML 第一行\n</div>\n\n正文\n", after: "HTML 第一行", line: "第二行"),
              "<div>\nHTML 第一行\n第二行\n</div>\n\n后\n\n正文\n")
        // 提示框下面空行隔开的普通引用：显示、保存、导出都是两段
        let q = makeView("> [!NOTE]\n> 提示内容\n\n> 普通引用\n")
        let plain = (q.string as NSString).range(of: "普通引用").location
        check("提示框下面空行隔开的普通引用不算提示框", "\((q.layoutManager as! RichLayoutManager).callout(at: plain, in: q.textStorage!) == nil)", "true")
        check("提示框和普通引用导出时分开", md(q), "> [!NOTE]\n> 提示内容\n\n> 普通引用\n")
        q.setSelectedRange(NSRange(location: NSMaxRange((q.string as NSString).range(of: "提示内容")), length: 0))
        type(q, "改")
        check("改了提示框再保存，普通引用不并进去", MarkdownCodec.serialize(RichBridge.blocks(from: q.textStorage!), preserving: "> [!NOTE]\n> 提示内容\n\n> 普通引用\n"),
              "> [!NOTE]\n> 提示内容改\n\n> 普通引用\n")
        q.insertNewline(nil)
        type(q, "第二行")
        check("提示框里回车的新行仍在提示框里", md(q), "> [!NOTE]\n> 提示内容改\n> 第二行\n\n> 普通引用\n")
        // 空行隔开的两段原样内容（带空行的待办、下面的 HTML）：显示成两张卡片，保存不变
        let rawSrc = "- [x] 已完成\n\n  第二段\n\n<div>HTML</div>\n"
        let r2 = makeView(rawSrc)
        let htmlAt = (r2.string as NSString).range(of: "<div>").location
        check("两段原样内容显示成两张卡片", "\(NSLocationInRange(htmlAt, (r2.layoutManager as! RichLayoutManager).codeBlock(at: 0) ?? NSRange()))", "false")
        check("两段原样内容导出不变", md(r2), rawSrc)
        r2.setSelectedRange(NSRange(location: NSMaxRange((r2.string as NSString).range(of: "第二段")), length: 0))
        type(r2, "改")
        check("改了上一段原样内容再保存，空行还在", md(r2), "- [x] 已完成\n\n  第二段改\n\n<div>HTML</div>\n")
        // 退出后撤销：只选回那个空行，打字不会删掉结尾的 ---
        do {
            let tv = makeView("---\ntitle: Demo\n---\n\n正文\n")
            let host = UndoHost(); tv.delegate = host
            tv.setSelectedRange(NSRange(location: NSMaxRange((tv.string as NSString).range(of: "title: Demo")), length: 0))
            step(host) { tv.insertNewline(nil) }
            step(host) { tv.insertNewline(nil) }
            host.um.undo()
            check("退出 YAML 后撤销只选回空行", "\(tv.selectedRange().length <= 1)", "true")
            step(host) { type(tv, "x") }
            check("退出 YAML 后撤销再打字，--- 还在", md(tv), "---\ntitle: Demo\nx\n---\n\n正文\n")
        }
        // 退出后撤销、重做来回几次：每次打字都不吃掉换行
        do {
            @MainActor func undoRedo(_ src: String, _ ops: [Bool]) -> String {
                let tv = makeView(src)
                let host = UndoHost(); tv.delegate = host
                tv.setSelectedRange(NSRange(location: NSMaxRange((tv.string as NSString).range(of: "title: Demo")), length: 0))
                step(host) { tv.insertNewline(nil) }
                step(host) { tv.insertNewline(nil) }
                for undo in ops { if undo { host.um.undo() } else { host.um.redo() } }
                step(host) { type(tv, "x") }
                return md(tv)
            }
            check("退出后撤销再重做，打字落在正文", undoRedo("---\ntitle: Demo\n---\n\n正文\n", [true, false]), "---\ntitle: Demo\n---\n\nx\n\n正文\n")
            check("退出后撤销、重做、再撤销，--- 还在", undoRedo("---\ntitle: Demo\n---\n\n正文\n", [true, false, true]), "---\ntitle: Demo\nx\n---\n\n正文\n")
            check("文末没换行的 YAML 退出后撤销再重做", undoRedo("---\ntitle: Demo\n---", [true, false]), "---\ntitle: Demo\n---\n\nx\n")
        }
        // 刚开出的空行打了空格、或光标挪走又回来：再回车不算“离开”
        do {
            let tv = makeView("---\ntitle: Demo\n---\n")
            tv.setSelectedRange(NSRange(location: NSMaxRange((tv.string as NSString).range(of: "title: Demo")), length: 0))
            tv.insertNewline(nil)
            type(tv, "  ")
            tv.insertNewline(nil)
            check("空行打了空格再回车不离开 YAML", md(tv), "---\ntitle: Demo\n  \n\n---\n")
            let t2 = makeView("- [x] a\n\n  b\n\n正文\n")
            t2.setSelectedRange(NSRange(location: NSMaxRange((t2.string as NSString).range(of: "- [x] a")), length: 0))
            t2.insertNewline(nil)
            t2.deleteBackward(nil)
            t2.setSelectedRange(NSRange(location: NSMaxRange((t2.string as NSString).range(of: "- [x] a")) + 1, length: 0))
            t2.insertNewline(nil)
            let t3 = makeView("- [x] a\n\n  b\n\n正文\n")
            t3.setSelectedRange(NSRange(location: NSMaxRange((t3.string as NSString).range(of: "- [x] a")) + 1, length: 0))
            t3.insertNewline(nil)
            t3.insertNewline(nil)
            type(t3, "后")
            check("原有空行回车开出新行，再回车离开", md(t3), "- [x] a\n\n  b\n\n后\n\n正文\n")
            check("退格后回到原有空行再回车不删空行", md(t2).hasPrefix("- [x] a\n\n\n  b") ? "ok" : md(t2), "ok")
        }
        // 选中了文字时按回车：替换成换行，不把原样内容变成正文
        do {
            let tv = makeView("---\ntitle: Demo\n  \n---\n")
            let spaces = (tv.string as NSString).range(of: "  \n")
            tv.setSelectedRange(NSRange(location: spaces.location, length: 2))
            tv.insertNewline(nil)
            check("选中 YAML 里的空格按回车不切开", md(tv).hasSuffix("---\n") && !md(tv).contains("&nbsp;") ? "ok" : md(tv), "ok")
        }
        // 文末的 YAML：退出后光标移走再回来，打的字仍是正文
        do {
            let tv = makeView("---\ntitle: Demo\n---\n")
            tv.setSelectedRange(NSRange(location: NSMaxRange((tv.string as NSString).range(of: "title: Demo")), length: 0))
            tv.insertNewline(nil)
            tv.insertNewline(nil)
            let at = tv.selectedRange()
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            tv.setSelectedRange(at)
            type(tv, "后")
            check("文末 YAML 退出后光标移走再回来仍是正文", md(tv), "---\ntitle: Demo\n---\n\n后\n")
        }
        // 原样列表里本来就有的空行：回车只是换行，不删这个空行
        do {
            let tv = makeView("- [x] a\n\n  b\n\n正文\n")
            let blank = NSMaxRange((tv.string as NSString).range(of: "- [x] a")) + 1
            tv.setSelectedRange(NSRange(location: blank, length: 0))
            tv.insertNewline(nil)
            check("原样列表里已有的空行回车不删", md(tv).hasPrefix("- [x] a\n\n\n  b") ? "ok" : md(tv), "ok")
        }
        // 粘贴：在 App 里复制的引用、原样内容贴进另一段里，不把那一段切开
        do {
            @MainActor func copyPaste(_ src: String, copy: String, before: String) -> String {
                let tv = makeView(src)
                let board = NSPasteboard(name: NSPasteboard.Name("DropMDTest8-\(UUID().uuidString)"))
                board.clearContents()
                let r = (tv.string as NSString).range(of: copy)
                tv.setSelectedRange(NSRange(location: r.location, length: r.length + 1))   // 连同换行，按段落粘贴
                _ = tv.writeSelection(to: board, types: tv.writablePasteboardTypes)
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: before).location, length: 0))
                _ = tv.readSelection(from: board)
                board.releaseGlobally()
                return md(tv)
            }
            check("引用行贴进提示框中间不切开", copyPaste("> [!NOTE]\n> 一\n> 二\n\n> 别的\n", copy: "别的", before: "二"),
                  "> [!NOTE]\n> 一\n> 别的\n> 二\n\n> 别的\n")
            @MainActor func copyAllPaste(_ src: String, into dst: String, before: String?) -> String {
                let from = makeView(src), to = makeView(dst)
                let board = NSPasteboard(name: NSPasteboard.Name("DropMDTest9-\(UUID().uuidString)"))
                board.clearContents()
                from.setSelectedRange(NSRange(location: 0, length: (from.string as NSString).length))
                _ = from.writeSelection(to: board, types: from.writablePasteboardTypes)
                to.setSelectedRange(NSRange(location: before.map { (to.string as NSString).range(of: $0).location } ?? 0, length: 0))
                _ = to.readSelection(from: board)
                board.releaseGlobally()
                return md(to)
            }
            check("复制两段 HTML 粘贴后仍是两段", copyAllPaste("<div>a</div>\n\n<div>b</div>\n", into: "\n", before: nil), "<div>a</div>\n\n<div>b</div>\n")
            check("复制提示框和普通引用粘贴后仍分开", copyAllPaste("> [!NOTE]\n> 注\n\n> 普通\n", into: "\n", before: nil), "> [!NOTE]\n> 注\n\n> 普通\n")
            check("普通引用贴在提示框标题前不并进提示框", copyAllPaste("> 普通\n", into: "> [!NOTE]\n> 注\n", before: nil).contains("普通\n\n> [!NOTE]") ? "ok" : "并进去了", "ok")
            check("带提示框的多段贴在普通引用上面不并进去", copyAllPaste("前言\n\n> [!NOTE]\n> 注\n", into: "> 普通\n", before: "普通").contains("> 注\n\n> 普通") ? "ok" : "并进去了", "ok")
            check("提示框贴在普通引用上面不并进去", copyAllPaste("> [!NOTE]\n> 注\n", into: "> 普通\n", before: "普通"), "> [!NOTE]\n> 注\n\n> 普通\n")
            check("原样内容贴进 HTML 中间不切开", copyPaste("---\ntitle: A\n---\n\n<div>\nhello\n</div>\n", copy: "title: A", before: "hello"),
                  "---\ntitle: A\n---\n\n<div>\ntitle: A\nhello\n</div>\n")
        }
        // 改提示框类型、插入提示框：下面隔空行的普通引用仍是另一段
        do {
            let tv = makeView("> [!NOTE]\n> 内容\n\n> 普通\n")
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "内容").location, length: 0))
            let item = NSMenuItem(); item.representedObject = MDCallout.warning.rawValue
            tv.setCalloutType(item)
            check("改提示框类型后普通引用仍分开", md(tv), "> [!WARNING]\n> 内容\n\n> 普通\n")
            let plain = (tv.string as NSString).range(of: "普通").location
            check("改类型后普通引用不画进提示框", "\((tv.layoutManager as! RichLayoutManager).callout(at: plain, in: tv.textStorage!) == nil)", "true")
            let t2 = makeView("开头\n\n> 普通\n")
            t2.setSelectedRange(NSRange(location: 2, length: 0))
            t2.insertCallout(.note)
            check("插入提示框不并进下面的普通引用", md(t2).contains("内容\n\n> 普通") ? "ok" : md(t2), "ok")
        }
        // 折叠块里的提示框不和外面的引用连成一段
        do {
            let tv = makeView("<details open>\n<summary>T</summary>\n\n> [!NOTE]\n> 里面\n\n</details>\n\n外面\n")
            let outside = (tv.string as NSString).range(of: "外面").location
            tv.setSelectedRange(NSRange(location: outside, length: 0))
            tv.setKind(.quote)   // 折叠块外紧挨着的正文改成引用：没有块编号
            check("折叠块外的引用不算里面的提示框", "\((tv.layoutManager as! RichLayoutManager).callout(at: outside, in: tv.textStorage!) == nil)", "true")
        }
        // 单页往返：紧挨着的两段原样内容打开再保存不变
        for src in ["---\ntitle: Demo\n---\n<div>HTML</div>\n", "- item\n\n  para 2\n<div>HTML</div>\n", "<div>a</div>\n\n\n<div>b</div>\n\n正文\n"] {
            let tv = makeView(src)
            check("单页打开再保存原样内容不变 \(src.debugDescription)", MarkdownCodec.serialize(RichBridge.blocks(from: tv.textStorage!), preserving: src), src)
        }
        check("YAML 在文末时中间空行再回车", exitMiddle("---\ntitle: Demo\n---\n", after: "title: Demo", line: "new: 1"),
              "---\ntitle: Demo\nnew: 1\n---\n\n后\n")
    }
    // 从网页、Word 粘贴：进表格单元格不拆表；替换整个标题、列表项的文字时样式不变
    do {
        @MainActor func paste(_ src: String, sel: String, rtf: String?, html: String?) -> String {
            let tv = makeView(src)
            tv.setSelectedRange((tv.string as NSString).range(of: sel))
            let board = NSPasteboard(name: NSPasteboard.Name("DropMDTest7-\(UUID().uuidString)"))
            board.clearContents()
            if let rtf {
                let s = NSAttributedString(string: rtf, attributes: [.font: NSFont.systemFont(ofSize: 14)])
                board.setData(try! s.data(from: NSRange(location: 0, length: s.length),
                                          documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]), forType: .rtf)
                board.setString(rtf, forType: .string)
            }
            if let html { board.setString(html, forType: .html) }
            _ = tv.readSelection(from: board)
            board.releaseGlobally()
            return md(tv)
        }
        check("网页内容粘进表格单元格", paste("| A | B |\n| --- | --- |\n| 1 | 2 |\n", sel: "1", rtf: "Title\nNext",
                                         html: "<h1>Title</h1><p>Next</p>"), "| A | B |\n| --- | --- |\n| Title Next | 2 |\n")
        check("粘贴替换整个标题的文字", paste("# 标题\n", sel: "标题", rtf: "Hello", html: nil), "# Hello\n")
        check("粘贴替换整个列表项的文字", paste("- 项目一\n- 项目二\n", sel: "项目一", rtf: "Hello", html: nil), "- Hello\n- 项目二\n")
    }
    // 显示用的颜色（临时属性，等主线程空下来才上色）
    do {
        @MainActor func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        @MainActor func color(_ tv: RichTextView, _ s: String) -> NSColor? {
            (tv.layoutManager as! RichLayoutManager).temporaryAttribute(.foregroundColor, atCharacterIndex: (tv.string as NSString).range(of: s).location, effectiveRange: nil) as? NSColor
        }
        var tv = makeView("> [!NOTE]\n> 第一行\n> 第二行\n")
        pump()
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "第一行").location, length: 0))
        tv.removeCallout(nil)
        pump()
        check("提示框变回引用后整段变灰", "\(color(tv, "第一行") == .secondaryLabelColor) \(color(tv, "第二行") == .secondaryLabelColor)", "true true")
        tv = makeView("<details>\n<summary>折叠</summary>\n\n```swift\n/* multi\nline comment */\n```\n\n</details>\n")
        pump()
        tv.setCollapsed(false, summary: (tv.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0)))
        pump()
        check("展开折叠块后代码注释上色", "\(color(tv, "line comment") == RichStyle.codeCommentColor)", "true")
        // 两个代码块之间的空行删掉后，屏幕上也是两块（和保存一致）
        tv = makeView("```swift\nlet a = 1\n```\n\n```python\nx = 2\n```\n")
        let gap = (tv.string as NSString).range(of: "\n\n").location + 1
        tv.setSelectedRange(NSRange(location: gap, length: 1))
        tv.delete(nil)
        check("删掉代码块间的空行后仍是两块", (tv.layoutManager as! RichLayoutManager).codeBlock(at: 0).map { (tv.string as NSString).substring(with: $0) } ?? "无", "let a = 1\n")
    }
    // 折叠块里多段复制到外面：去掉折叠块标记和缩进，保留各自段落样式；粘进另一个折叠块时仍归那一块
    do {
        @MainActor func copyPaste(_ src: String, copyStart: String, copyEnd: String, includeEndNewline: Bool = true, into: NSRange) -> RichTextView {
            let tv = makeView(src)
            let ns = tv.string as NSString
            let s = ns.range(of: copyStart).location
            let e = ns.range(of: copyEnd)
            let end = includeEndNewline ? NSMaxRange(e) : NSMaxRange(e)
            let board = NSPasteboard(name: NSPasteboard.Name("DropMDTestDetails-\(UUID().uuidString)"))
            board.clearContents()
            tv.setSelectedRange(NSRange(location: s, length: end - s))
            _ = tv.writeSelection(to: board, types: tv.writablePasteboardTypes)
            tv.setSelectedRange(into)
            _ = tv.readSelection(from: board)
            board.releaseGlobally()
            return tv
        }
        @MainActor func attrs(of tv: RichTextView, last needle: String) -> [NSAttributedString.Key: Any] {
            let r = (tv.string as NSString).range(of: needle, options: .backwards)
            return tv.textStorage!.attributes(at: r.location, effectiveRange: nil)
        }

        let src1 = "<details open>\n<summary>折叠</summary>\n\n## 小标题\n\n- **粗** 和 *斜* 和 `代码`\n\n普通 [链接](https://example.com)\n\n</details>\n"
        let tv0 = makeView(src1)
        let tv1 = copyPaste(src1, copyStart: "小标题", copyEnd: "普通 链接\n", into: NSRange(location: (tv0.string as NSString).length - 1, length: 0))
        check("折叠块内多段粘到块外空段：Markdown", md(tv1),
              src1 + "\n## 小标题\n\n- **粗** 和 *斜* 和 `代码`\n\n普通 [链接](https://example.com)\n")
        let aH = attrs(of: tv1, last: "小标题"), aL = attrs(of: tv1, last: "粗"), aB = attrs(of: tv1, last: "普通")
        let indentH = (aH[.paragraphStyle] as? NSParagraphStyle)?.firstLineHeadIndent ?? -1
        let indentL = (aL[.paragraphStyle] as? NSParagraphStyle)?.firstLineHeadIndent ?? -1
        let indentB = (aB[.paragraphStyle] as? NSParagraphStyle)?.firstLineHeadIndent ?? -1
        check("折叠块内多段粘到块外空段：属性与缩进",
              "\(aH[DMKey.inDetails] == nil) \(aL[DMKey.inDetails] == nil) \(aB[DMKey.inDetails] == nil) \(indentH) \(indentL) \(indentB)",
              "true true true 0.0 \(RichStyle.indent) 0.0")

        let src2 = "<details open>\n<summary>折</summary>\n\n第一段\n\n第二段\n\n</details>\n\n隔开\n\n落点\n"
        let tv2 = copyPaste(src2, copyStart: "第一段", copyEnd: "第二段", into: (makeView(src2).string as NSString).range(of: "落点"))
        check("折叠块内多段粘到远处正文", md(tv2),
              "<details open>\n<summary>折</summary>\n\n第一段\n\n第二段\n\n</details>\n\n隔开\n\n第一段\n\n第二段\n")
        let a2a = attrs(of: tv2, last: "第一段"), a2b = attrs(of: tv2, last: "第二段")
        check("折叠块内多段粘到远处正文：属性与缩进",
              "\(a2a[DMKey.inDetails] == nil) \(a2b[DMKey.inDetails] == nil) \((a2a[.paragraphStyle] as? NSParagraphStyle)?.firstLineHeadIndent ?? -1) \((a2b[.paragraphStyle] as? NSParagraphStyle)?.firstLineHeadIndent ?? -1)",
              "true true 0.0 0.0")

        let src3 = "<details open>\n<summary>甲</summary>\n\n## 标题\n\n- 列表\n\n</details>\n\n<details open>\n<summary>乙</summary>\n\n原有\n\n</details>\n"
        let tv3 = copyPaste(src3, copyStart: "标题", copyEnd: "列表\n", into: (makeView(src3).string as NSString).range(of: "原有"))
        check("折叠块内多段粘进另一个折叠块", md(tv3),
              "<details open>\n<summary>甲</summary>\n\n## 标题\n\n- 列表\n\n</details>\n\n<details open>\n<summary>乙</summary>\n\n## 标题\n\n- 列表\n\n</details>\n")
        let a3H = attrs(of: tv3, last: "标题"), a3L = attrs(of: tv3, last: "列表")
        check("折叠块内多段粘进另一个折叠块：属性与缩进",
              "\(a3H[DMKey.inDetails] != nil) \(a3L[DMKey.inDetails] != nil) \((a3H[.paragraphStyle] as? NSParagraphStyle)?.firstLineHeadIndent ?? -1) \((a3L[.paragraphStyle] as? NSParagraphStyle)?.firstLineHeadIndent ?? -1)",
              "true true \(RichStyle.detailsIndent) \(RichStyle.indent + RichStyle.detailsIndent)")

        let src4 = "<details open>\n<summary>折</summary>\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n</details>\n"
        let tv4 = copyPaste(src4, copyStart: "A", copyEnd: "2\n", into: NSRange(location: (makeView(src4).string as NSString).length - 1, length: 0))
        check("折叠块内表格粘到块外", md(tv4),
              "<details open>\n<summary>折</summary>\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n</details>\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n")
        let a4 = attrs(of: tv4, last: "1")
        check("折叠块内表格粘到块外：属性与左边距",
              "\(a4[DMKey.inDetails] == nil) \(RichBridge.tableBlock(of: a4)?.table.width(for: .margin, edge: .minX) ?? -1)",
              "true 0.0")
    }
    // 行内粘贴：立刻使用目标段落的字号和基础字体，保留行内格式（粗体、斜体、代码、链接）
    do {
        @MainActor func copyPasteInline(_ src: String, copy: String, at target: String) -> RichTextView {
            let tv = makeView(src)
            let ns = tv.string as NSString
            let board = NSPasteboard(name: NSPasteboard.Name("DropMDTestInline-\(UUID().uuidString)"))
            board.clearContents()
            tv.setSelectedRange(ns.range(of: copy))
            _ = tv.writeSelection(to: board, types: tv.writablePasteboardTypes)
            tv.setSelectedRange(NSRange(location: ns.range(of: target).location, length: 0))
            _ = tv.readSelection(from: board)
            board.releaseGlobally()
            return tv
        }
        @MainActor func info(_ tv: RichTextView, _ needle: String, backwards: Bool) -> (size: CGFloat, bold: Bool, italic: Bool, code: Bool, link: String?, kern: Double?) {
            let r = (tv.string as NSString).range(of: needle, options: backwards ? .backwards : [])
            let a = tv.textStorage!.attributes(at: r.location, effectiveRange: nil)
            let font = a[.font] as? NSFont
            return (font?.pointSize ?? 0, RichStyle.isBold(font), ((a[.obliqueness] as? Double) ?? 0) != 0,
                    a[DMKey.inlineCode] != nil, a[DMKey.link] as? String, a[.kern] as? Double)
        }

        let tv1 = copyPasteInline("# 标题 *斜* `代码` [链](https://example.com)\n\n前后\n", copy: "标题 斜 代码 链", at: "后")
        check("标题片段行内粘进正文：Markdown", md(tv1),
              "# 标题 *斜* `代码` [链](https://example.com)\n\n前标题 *斜* `代码` [链](https://example.com)后\n")
        let i1t = info(tv1, "标题", backwards: true), i1i = info(tv1, "斜", backwards: true)
        let i1c = info(tv1, "代码", backwards: true), i1l = info(tv1, "链", backwards: true)
        check("标题片段行内粘进正文：字号与格式",
              "\(i1t.size) \(i1t.bold) \(i1t.kern == nil) | \(i1i.size) \(i1i.italic) \(i1i.bold) | \(i1c.code) \(i1c.size) \(i1c.bold) | \(i1l.link ?? "") \(i1l.size) \(i1l.bold)",
              "\(RichStyle.bodySize) false true | \(RichStyle.bodySize) true false | true \(RichStyle.inlineCodeSize) false | https://example.com \(RichStyle.bodySize) false")

        let tv2 = copyPasteInline("甲 **粗** *斜* `码` [链](https://example.com)\n\n前后\n", copy: "粗 斜 码 链", at: "后")
        check("正文带格式片段行内粘进正文：保留粗体等格式", md(tv2),
              "甲 **粗** *斜* `码` [链](https://example.com)\n\n前**粗** *斜* `码` [链](https://example.com)后\n")
        let i2b = info(tv2, "粗", backwards: true)
        check("正文带格式片段行内粘进正文：粗体字号", "\(i2b.size) \(i2b.bold)", "\(RichStyle.bodySize) true")

        let tv3 = copyPasteInline("## 标头\n\n普通 **粗** *斜* `码` [链](https://example.com)\n", copy: "普通 粗 斜 码 链", at: "头")
        check("正文片段行内粘进标题：Markdown", md(tv3),
              "## 标普通 粗 *斜* `码` [链](https://example.com)头\n\n普通 **粗** *斜* `码` [链](https://example.com)\n")
        let h2Size = RichStyle.baseFont(for: .heading(2)).pointSize
        let i3p = info(tv3, "普通", backwards: false), i3i = info(tv3, "斜", backwards: false)
        let i3c = info(tv3, "码", backwards: false), i3l = info(tv3, "链", backwards: false)
        check("正文片段行内粘进标题：字号与格式",
              "\(i3p.size) \(i3p.bold) \(i3p.kern ?? 0) | \(i3i.size) \(i3i.italic) | \(i3c.code) \(i3c.size) | \(i3l.link ?? "") \(i3l.size)",
              "\(h2Size) true -0.2 | \(h2Size) true | true \(RichStyle.inlineCodeSize) | https://example.com \(h2Size)")
    }
    // 列表项里的代码块变回正文：变成同一列表的项目，不断开列表
    do {
        for (name, src, want) in [
            ("无序列表代码块变回正文", "- 项目一\n\n  ```\n  code\n  ```\n- 项目二\n", "- 项目一\n- code\n- 项目二\n"),
            ("有序列表代码块变回正文", "1. 第一步\n\n   ```\n   code\n   ```\n2. 第二步\n", "1. 第一步\n2. code\n3. 第二步\n"),
        ] {
            let tv = makeView(src)
            let loc = (tv.string as NSString).range(of: "code").location
            tv.setSelectedRange(NSRange(location: loc, length: 0))
            tv.setKind(.body)
            check(name, md(tv), want)
        }
    }
    // 离开原样块后，下一段保留卡片下方的间距
    do {
        @MainActor func gapBeforeBody(_ tv: RichTextView) -> CGFloat {
            let lm = tv.layoutManager!
            lm.ensureLayout(for: tv.textContainer!)
            let g = lm.glyphIndexForCharacter(at: (tv.string as NSString).range(of: "正文").location)
            let cur = lm.lineFragmentUsedRect(forGlyphAt: g, effectiveRange: nil)
            let prev = lm.lineFragmentUsedRect(forGlyphAt: g - 1, effectiveRange: nil)
            return cur.minY - prev.maxY
        }
        let tv = makeView("<div>\nx\n</div>\n")
        let xEnd = NSMaxRange((tv.string as NSString).range(of: "x"))
        tv.setSelectedRange(NSRange(location: xEnd, length: 0))
        tv.insertNewline(nil)
        tv.insertNewline(nil)
        type(tv, "正文")
        let fresh = makeView("<div>\nx\n</div>\n\n正文\n")
        check("离开原样块后保留卡片下方间距", "\(gapBeforeBody(tv))", "\(gapBeforeBody(fresh))")
    }
    do {   // 多行的列表代码块整体变回正文：每行都变成列表项，编号接上
        let tv = makeView("1. 第一步\n\n   ```bash\n   echo a\n   echo b\n   ```\n\n2. 第二步\n")
        let ns = tv.string as NSString
        let a = ns.range(of: "echo a").location, b = NSMaxRange(ns.range(of: "echo b"))
        tv.setSelectedRange(NSRange(location: a, length: b - a))
        tv.setKind(.body)
        check("多行列表代码块变回正文", md(tv), "1. 第一步\n2. echo a\n3. echo b\n4. 第二步\n")
    }
    do {   // 外部 RTF 粘贴一行列表项（带 NSTextList）：去掉列表符号后不越界、不改下一段
        let list = NSTextList(markerFormat: .disc, options: 0)
        let ps = NSMutableParagraphStyle(); ps.textLists = [list]
        let item = NSAttributedString(string: "\t•\t苹果", attributes: [.paragraphStyle: ps, .font: NSFont.systemFont(ofSize: 13)])
        let rtf = item.rtf(from: NSRange(location: 0, length: item.length), documentAttributes: [:])!
        do {
            let tv = makeView("")
            let board = NSPasteboard(name: NSPasteboard.Name("DropMDTestRTFList-\(UUID().uuidString)"))
            board.clearContents()
            board.setData(rtf, forType: .rtf)
            tv.setSelectedRange(NSRange(location: tv.string.utf16.count, length: 0))
            _ = tv.readSelection(from: board, type: .rtf)
            board.releaseGlobally()
            check("RTF 一行列表项粘到空文档末尾", md(tv), "苹果\n")
        }
    }
    do {   // 折叠块内含行内公式、图片的标题：按模型文字匹配找得到段落
        let doc = "<details>\n<summary>折叠</summary>\n\n## 公式 $E=mc^2$\n\n## 图标 ![logo](logo.png) 说明\n\n</details>\n"
        let tv = makeView(doc)
        let ns = tv.string as NSString
        let titles = extractHeadings(doc).map(\.title)
        check("含公式与图片的标题：大纲提取", titles.joined(separator: " | "), "公式 $E=mc^2$ | 图标 logo 说明")
        let mathPara = tv.headingParagraph(title: titles[0], occurrence: 0).map { ns.substring(with: $0).trimmingCharacters(in: .newlines) } ?? "无"
        let imgPara = tv.headingParagraph(title: titles[1], occurrence: 0).map { ns.substring(with: $0).trimmingCharacters(in: .newlines) } ?? "无"
        check("含行内公式的标题：headingParagraph", mathPara, "公式 \u{FFFC}")
        check("含图片的标题：headingParagraph", imgPara, "图标 \u{FFFC} 说明")
    }
    // 别的程序复制来的多行代码（剪贴板有 RTF，末尾没有换行）贴进代码块中间的空行：仍是一整块，语言不变
    do {
        let tv = makeView("```python\nx = 1\n\ny = 2\n```\n")
        let pb = NSPasteboard(name: NSPasteboard.Name("dropmd-test-\(UUID().uuidString)"))
        let code = "let a = 1\nlet b = 2"
        let rich = NSAttributedString(string: code, attributes: [.font: NSFont(name: "Menlo", size: 12)!])
        pb.declareTypes([.rtf, .string], owner: nil)
        pb.setData(rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]), forType: .rtf)
        pb.setString(code, forType: .string)
        tv.setSelectedRange(NSRange(location: ("x = 1\n" as NSString).length, length: 0))
        _ = tv.readSelection(from: pb, type: .rtf)
        check("外部多行代码贴进代码块", md(tv), "```python\nx = 1\nlet a = 1\nlet b = 2\ny = 2\n```\n")
        pb.releaseGlobally()
    }
    // 单页之间复制的 swift 代码块贴进 python 代码块中间：用目标的语言和块编号，不把它拆开
    do {
        let src = makeView("```swift\nlet a = 1\nlet b = 2\n```\n")
        src.setSelectedRange(NSRange(location: 0, length: (src.string as NSString).length))
        let pb = NSPasteboard(name: NSPasteboard.Name("dropmd-test-\(UUID().uuidString)"))
        let rich = NSPasteboard.PasteboardType("io.github.dropmd.rich")
        _ = src.writeSelection(to: pb, types: [rich])
        let tv = makeView("```python\nx = 1\ny = 2\n```\n")
        tv.setSelectedRange(NSRange(location: ("x = 1\n" as NSString).length, length: 0))
        _ = tv.readSelection(from: pb, type: rich)
        check("单页内多行代码贴进别的语言的代码块", md(tv), "```python\nx = 1\nlet a = 1\nlet b = 2\ny = 2\n```\n")
        pb.releaseGlobally()
    }
    // 代码块或提示框下方的正文，改成不同语言的代码块或普通引用时不吸进上一块
    do {
        let tv1 = makeView("```python\nx = 1\n```\n\nlet a = 2\n")
        tv1.setSelectedRange(NSRange(location: (tv1.string as NSString).range(of: "let a = 2").location, length: 0))
        tv1.setKind(.code("swift"))
        check("代码块下方正文设为不同语言代码块不合并", md(tv1), "```python\nx = 1\n```\n\n```swift\nlet a = 2\n```\n")
        let tv2 = makeView("> [!NOTE]\n> 提示内容\n\n普通文字\n")
        tv2.setSelectedRange(NSRange(location: (tv2.string as NSString).range(of: "普通文字").location, length: 0))
        tv2.setKind(.quote)
        check("提示框下方正文设为普通引用不并入提示框", md(tv2), "> [!NOTE]\n> 提示内容\n\n> 普通文字\n")
    }
    // 回归测试：纯 HTML 贴进表格不拆表、外部贴进表头保留粗体、多段贴进折叠块标题行压成单行、空正文段贴单行网页 h1 保留标题
    do {
        // a. 纯 HTML（无 .rtf / .string）贴进表格单元格不拆表
        do {
            let tv = makeView("| A | B |\n| --- | --- |\n| 1 | 2 |\n")
            tv.setSelectedRange((tv.string as NSString).range(of: "1"))
            let board = NSPasteboard(name: NSPasteboard.Name("DropMDTestTableHTML-\(UUID().uuidString)"))
            board.clearContents()
            board.setString("<h1>Title</h1><p>Next</p>", forType: .html)
            _ = tv.readSelection(from: board)
            board.releaseGlobally()
            check("纯 HTML 粘进表格单元格不拆表", md(tv), "| A | B |\n| --- | --- |\n| Title Next | 2 |\n")
        }
        // b. 外部文本粘进表头单元格保留粗体
        do {
            let tv = makeView("| A | B |\n| --- | --- |\n| 1 | 2 |\n")
            tv.setSelectedRange((tv.string as NSString).range(of: "A"))
            let board = NSPasteboard(name: NSPasteboard.Name("DropMDTestTableHeader-\(UUID().uuidString)"))
            board.clearContents()
            board.setString("HeaderNew", forType: .string)
            _ = tv.readSelection(from: board)
            board.releaseGlobally()
            let r = (tv.string as NSString).range(of: "HeaderNew")
            let font = tv.textStorage!.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont
            check("外部粘贴进表头单元格：Markdown 与粗体", "\(md(tv))|\(RichStyle.isBold(font))", "| HeaderNew | B |\n| --- | --- |\n| 1 | 2 |\n|true")
        }
        // c. 多段内容粘进 <details> 折叠块标题行（<summary>）压成单行不拆折叠块
        do {
            let src = makeView("第一段\n\n第二段\n")
            src.setSelectedRange(NSRange(location: 0, length: (src.string as NSString).length))
            let board = NSPasteboard(name: NSPasteboard.Name("DropMDTestSummaryPaste-\(UUID().uuidString)"))
            board.clearContents()
            _ = src.writeSelection(to: board, types: src.writablePasteboardTypes)
            let tv = makeView("<details>\n<summary>折叠标题</summary>\n\n折叠内容\n\n</details>\n")
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "标题").location, length: 0))
            _ = tv.readSelection(from: board)
            board.releaseGlobally()
            check("多段粘进折叠块标题行不拆折叠块", md(tv), "<details>\n<summary>折叠第一段 第二段标题</summary>\n\n折叠内容\n\n</details>\n")
        }
        // d. 单行网页 <h1> 粘进空正文段落保留标题样式
        do {
            let tv = makeView("\n")
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            let board = NSPasteboard(name: NSPasteboard.Name("DropMDTestSingleH1-\(UUID().uuidString)"))
            board.clearContents()
            let s = NSAttributedString(string: "网页大标题", attributes: [.font: NSFont.boldSystemFont(ofSize: 24)])
            board.setData(try! s.data(from: NSRange(location: 0, length: s.length),
                                      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]), forType: .rtf)
            board.setString("<html><body><h1>网页大标题</h1></body></html>", forType: .html)
            _ = tv.readSelection(from: board)
            board.releaseGlobally()
            check("单行网页 h1 粘进空正文段落保留标题", md(tv), "# 网页大标题\n")
        }
    }
    // 导出为 Word（.docx，beta）：标题层级、列表、表格、折叠块、本机图片与隐私拦截、超链接、代码块、扩展行内格式
    if WordExport.pandocExecutable() != nil {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("DropMDWordTest-\(UUID().uuidString)", isDirectory: true)
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let imgDir = dir.appendingPathComponent("图 片", isDirectory: true)
        let subDir = dir.appendingPathComponent("subdir", isDirectory: true)
        try! fm.createDirectory(at: imgDir, withIntermediateDirectories: true)
        try! fm.createDirectory(at: subDir, withIntermediateDirectories: true)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        try! png.write(to: imgDir.appendingPathComponent("测试 图.png"))
        try! png.write(to: dir.appendingPathComponent("50%20off.png"))
        let dataPng = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

        @MainActor func unzipDocx(_ url: URL, into name: String) -> (doc: String, rels: String, styles: String, media: [String]) {
            let unpack = dir.appendingPathComponent(name, isDirectory: true)
            try? fm.removeItem(at: unpack)
            try! fm.createDirectory(at: unpack, withIntermediateDirectories: true)
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", url.path, unpack.path]
            try! ditto.run()
            ditto.waitUntilExit()
            check("解压 \(name)", "\(ditto.terminationStatus)", "0")
            let doc = (try? String(contentsOf: unpack.appendingPathComponent("word/document.xml"), encoding: .utf8)) ?? ""
            let rels = (try? String(contentsOf: unpack.appendingPathComponent("word/_rels/document.xml.rels"), encoding: .utf8)) ?? ""
            let styles = (try? String(contentsOf: unpack.appendingPathComponent("word/styles.xml"), encoding: .utf8)) ?? ""
            let media = (try? fm.contentsOfDirectory(atPath: unpack.appendingPathComponent("word/media").path)) ?? []
            return (doc, rels, styles, media)
        }

        let sample = """
        ---
        title: [bad: yaml
        ---

        # 一级标题
        ## 二级标题
        ### 三级标题
        #### 四级标题
        ##### 五级标题
        ###### 六级标题

        正文包含 <u>下划线</u>、H<sub>2</sub>O、x<sup>2</sup>、==高亮==、**相邻粗***相邻斜*、*相邻斜二***相邻粗二**、<b>粗标签</b>、<i>斜标签</i>、<s>删标签</s>、<del>删二</del> 和 [官网](https://example.com)。

        - 无序 1
        - 无序 2
          - 嵌套无序

        1. 有序 1
        2. 有序 2

        > [!NOTE]
        > 提示框内容

        ```swift
        let a = 1
        print(a)
        ```

        结果如下：
        | 紧贴A | 紧贴B |
        | --- | --- |
        | 1 | 2 |

        | 列 A | 列 B |
        | :-- | --: |
        | 1 | 2 |

        <details>
        <summary>折叠标题一</summary>

        折叠正文一

        </details>

        <details>
        <summary>折叠标题二</summary>
        折叠正文二
        </details>

        ![本地图](%E5%9B%BE%20%E7%89%87/%E6%B5%8B%E8%AF%95%20%E5%9B%BE.png)

        ![百分号图](50%2520off.png)

        ![内嵌图](\(dataPng))

        ![目录](subdir)

        ![缺失图](missing.png)

        ![网络图](https://127.0.0.1:9999/should_not_fetch.png)

        ![](https://127.0.0.1:9999/empty_alt_secret.png)

        ![空格图](< https://127.0.0.1:9999/space_secret.png>)

        ![协议图](//127.0.0.1:9999/proto_secret.png)

        ![FTP图](ftp://127.0.0.1:9999/ftp_secret.png)

        ![本地URI](file:///etc/hosts)

        ![非图Data](data:text/html;base64,PGI+eDwvYj4=)
        """
        let outDocx = dir.appendingPathComponent("out.docx")
        try! WordExport.export(markdown: sample, to: outDocx, base: dir)
        let res = unzipDocx(outDocx, into: "unpacked")
        let leaked = ["should_not_fetch", "empty_alt_secret", "space_secret", "proto_secret", "ftp_secret", "etc/hosts", "PGI+"]
            .contains { res.doc.contains($0) || res.rels.contains($0) }
        let tblCount = res.doc.components(separatedBy: "<w:tbl>").count - 1

        let checks: [(String, Bool)] = [
            ("Word 导出标题层级 H1-H6", (1...6).allSatisfy { res.doc.contains("Heading\($0)") }),
            ("Word 导出有序与嵌套无序列表", res.doc.contains("<w:numPr>") && res.doc.contains("w:ilvl w:val=\"1\"")),
            ("Word 导出紧贴表格与网格边框", tblCount >= 2 && res.doc.contains("紧贴A") && !res.doc.contains("| 紧贴A |") && res.styles.contains("w:insideH") && res.styles.contains("w:insideV")),
            ("Word 导出折叠块标题与正文", ["折叠标题一", "折叠正文一", "折叠标题二", "折叠正文二"].allSatisfy { res.doc.contains($0) }),
            ("Word 导出嵌入本地图与百分号文件名", res.doc.contains("r:embed=") && res.media.count == 3),
            ("Word 导出拦截所有外部/异常图片方案", !leaked && res.doc.contains("网络图片未加载（隐私保护）") && res.doc.contains("缺失图") && !res.doc.contains("missing.png")),
            ("Word 导出超链接", res.doc.contains("Hyperlink") && res.rels.contains("https://example.com")),
            ("Word 导出代码块与浅灰底色", res.doc.contains("SourceCode") && res.styles.contains("F6F8FA") && res.styles.contains("1D1D1F") && res.styles.contains("w:line=\"324\"")),
            ("Word 导出行内样式与 HTML 标签", res.doc.contains("w:u ") && res.doc.contains("subscript") && res.doc.contains("superscript") && res.doc.contains("w:highlight") && res.doc.contains("<w:b") && res.doc.contains("<w:i") && res.doc.contains("<w:strike") && ["相邻粗", "相邻斜", "粗标签", "斜标签", "删标签", "删二"].allSatisfy { res.doc.contains($0) }),
        ]
        for (name, ok) in checks {
            check(name, ok ? "ok" : "fail", "ok")
        }

        // 覆盖已有文件与悬空符号链接
        try! WordExport.export(markdown: "# 覆盖成功\n", to: outDocx, base: dir)
        check("Word 导出覆盖已有文件", unzipDocx(outDocx, into: "unpacked_overwrite").doc.contains("覆盖成功") ? "ok" : "fail", "ok")
        let dangling = dir.appendingPathComponent("dangling.docx")
        try! fm.createSymbolicLink(at: dangling, withDestinationURL: dir.appendingPathComponent("nonexistent-target.docx"))
        try! WordExport.export(markdown: "# 悬空链接\n", to: dangling, base: dir)
        check("Word 导出覆盖悬空符号链接", unzipDocx(dangling, into: "unpacked_dangling").doc.contains("悬空链接") ? "ok" : "fail", "ok")

        // 未保存文档（base: nil）不读相对路径图片，且开头 % 不被当作文档标题
        let noBaseDocx = dir.appendingPathComponent("nobase.docx")
        try! WordExport.export(markdown: "% completion rate\n\n# 标题\n\n![相对图](50%2520off.png)\n", to: noBaseDocx, base: nil)
        let noBase = unzipDocx(noBaseDocx, into: "unpacked_nobase")
        check("Word 导出禁用 pandoc_title_block 且无 base 时不读相对图",
              noBase.doc.contains("% completion rate") && !noBase.doc.contains("w:val=\"Title\"") && noBase.media.isEmpty ? "ok" : "fail", "ok")

        // 非图片扩展名本地文件禁止通过图片语法嵌入
        let secretTxt = dir.appendingPathComponent("secret.txt")
        try! "TOP_SECRET_TEXT".write(to: secretTxt, atomically: true, encoding: .utf8)
        let nonImageDocx = dir.appendingPathComponent("nonimage.docx")
        try! WordExport.export(markdown: "![文本](secret.txt)\n\n![无后缀](/etc/hosts)\n", to: nonImageDocx, base: dir)
        let nonImage = unzipDocx(nonImageDocx, into: "unpacked_nonimage")
        check("Word 导出拦截非图片扩展名本地文件",
              nonImage.media.isEmpty && !nonImage.doc.contains("TOP_SECRET_TEXT") && nonImage.doc.contains("文本") && nonImage.doc.contains("无后缀") ? "ok" : "fail", "ok")

        // 真实示例文档导出检查
        if let sampleText = try? String(contentsOfFile: "packaging/samples/editor_sample.md", encoding: .utf8) {
            let sampleDocx = dir.appendingPathComponent("editor_sample.docx")
            try! WordExport.export(markdown: sampleText, to: sampleDocx, base: URL(fileURLWithPath: "packaging/samples", isDirectory: true))
            let s = unzipDocx(sampleDocx, into: "unpacked_sample")
            check("Word 导出示例文档结构完整",
                  s.doc.contains("Heading1") && s.doc.contains("<w:tbl>") && s.doc.contains("Hyperlink")
                      && s.rels.contains("https://example.com") && s.doc.contains("点击展开的折叠块") && s.doc.contains("折叠块里的内容") ? "ok" : "fail",
                  "ok")
        }
    } else {
        print("跳过 Word 导出测试（未找到 Pandoc）")
        let tmpOut = FileManager.default.temporaryDirectory.appendingPathComponent("dropmd-nopandoc-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: tmpOut) }
        do {
            try WordExport.export(markdown: "# 测试\n", to: tmpOut, base: nil)
            check("无 Pandoc 时导出应报错", "did not throw", "throw")
        } catch {
            check("无 Pandoc 时返回本地化错误", error.localizedDescription.isEmpty ? "empty" : "ok", "ok")
        }
    }

    // 字号缩放（TextScale）：固定比例 + 自动模式按窗口宽度（而非单个编辑区宽度）
    do {
        check("字号缩放固定比例", "\(TextScale.large.scale(screen: nil, viewWidth: 500)) \(TextScale.medium.scale(screen: nil, viewWidth: 500)) \(TextScale.small.scale(screen: nil, viewWidth: 500))",
              "\(18.0 / 16.0) 1.0 \(15.0 / 16.0)")
        check("字号自动在窄窗口时不放大", "\(TextScale.auto.scale(screen: NSScreen.main, viewWidth: 700))", "1.0")
        let oldScale = UserDefaults.standard.string(forKey: "textScale")
        defer {
            if let oldScale { UserDefaults.standard.set(oldScale, forKey: "textScale") }
            else { UserDefaults.standard.removeObject(forKey: "textScale") }
        }
        UserDefaults.standard.set("large", forKey: "textScale")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 400))
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 800))
        scroll.documentView = doc
        TextScale.apply(to: scroll)
        check("TextScale.apply 应用大字号", "\(scroll.magnification)", "\(18.0 / 16.0)")

        UserDefaults.standard.set("auto", forKey: "textScale")
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 660), styleMask: [.titled], backing: .buffered, defer: false)
        // 双页左边只有 490 宽，但所在窗口是 980 宽 (>= 760)：应按窗口宽度算，两边字号一致
        let leftScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 490, height: 600))
        let rightScroll = NSScrollView(frame: NSRect(x: 490, y: 0, width: 490, height: 600))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 980, height: 600))
        container.addSubview(leftScroll)
        container.addSubview(rightScroll)
        win.contentView = container
        TextScale.apply(to: leftScroll)
        TextScale.apply(to: rightScroll)
        let expectedAuto = TextScale.auto.scale(screen: win.screen, viewWidth: win.frame.width)
        check("双页左右字号按窗口宽度一致", "\(leftScroll.magnification == rightScroll.magnification) \(abs(leftScroll.magnification - expectedAuto) < 0.001)", "true true")
    }

    // 行号栏（SourceLineNumberRulerView）与源码视图（SourceTextView）对应位置标记开关
    do {
        let oldMark = UserDefaults.standard.object(forKey: "showSourceMark")
        defer {
            if let oldMark { UserDefaults.standard.set(oldMark, forKey: "showSourceMark") }
            else { UserDefaults.standard.removeObject(forKey: "showSourceMark") }
        }
        let storage = NSTextStorage(string: "line 1\nline 2\nline 3\n")
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        lm.addTextContainer(tc)
        let tv = SourceTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: tc)
        let scroll = SplitScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scroll.documentView = tv
        let ruler = SourceLineNumberRulerView(scrollView: scroll, textView: tv)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        lm.ensureLayout(for: tc)

        tv.string = "\u{00E9}\n第二行\n"
        check("组合重音替换前的滚动行号与行首", "\(ruler.lineIndex(forCharacter: 2)) \(ruler.characterIndex(forLine: 1))", "1 2")
        storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "e\u{0301}")
        check("组合重音替换后更新 UTF-16 行首与滚动行号", "\(ruler.lineIndex(forCharacter: 2)) \(ruler.lineIndex(forCharacter: 3)) \(ruler.characterIndex(forLine: 1))", "0 1 3")

        let thinThickness = ruler.ruleThickness
        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: String(repeating: "x\n", count: 100))
        let wideThickness = ruler.ruleThickness
        check("行号栏超过 100 行自动加宽", "\(wideThickness > thinThickness)", "true")

        tv.markedLines = NSRange(location: 0, length: 6)
        UserDefaults.standard.set(true, forKey: "showSourceMark")
        let rectOn = tv.markedLinesRect()
        UserDefaults.standard.set(false, forKey: "showSourceMark")
        let rectOff = tv.markedLinesRect()
        check("关掉显示对应位置标记后高亮立即消失", "\(!rectOn.isEmpty) \(rectOff.isEmpty)", "true true")

        // 文本刚替换（尚未显式 ensureLayout）时，markedLinesRect 仍能按折行算完整矩形
        UserDefaults.standard.set(true, forKey: "showSourceMark")
        let wrapped = String(repeating: "这是一段用来触发折行的长文字 ", count: 6) + "\n"
        tv.string = wrapped
        tv.markedLines = NSRange(location: 0, length: (wrapped as NSString).length - 1)
        let wrappedRect = tv.markedLinesRect()
        check("双页长行未预先排版时黄色高亮仍完整覆盖折行", "\(wrappedRect.height > 28)", "true")
    }

    do {
        let answer = "**重点**\n\n[说明](https://example.com)"
        let item = DocumentQAItem(question: "问题", answer: answer)
        let rendered = item.displayAnswer
        let isBold = rendered.runs.first?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        check("问答格式化粗体、保留换行、不激活生成的链接", "\(String(rendered.characters)) \(isBold) \(rendered.runs.allSatisfy { $0.link == nil })", "重点\n\n说明 true true")
        let error = DocumentQAItem(question: "问题", answer: answer, isError: true)
        check("问答错误提示保留原文", String(error.displayAnswer.characters), answer)
        let listAnswer = DocumentQAItem(question: "问题", answer: "## 待办\n- 确认 **酒店**\n  * 发 H<sub>2</sub>O 议程[^1]")
        check("问答列表显示圆点、去掉标题符号与 HTML 标签", String(listAnswer.displayAnswer.characters), "待办\n• 确认 酒店\n• 发 H2O 议程")
        let taskAnswer = DocumentQAItem(question: "问题", answer: "- [ ] 确认酒店\n- [x] 预订会议室")
        check("问答待办框显示为勾选框符号", String(taskAnswer.displayAnswer.characters), "☐ 确认酒店\n☑ 预订会议室")
        check("问答加粗的待办框也显示为勾选框符号", String(DocumentQAItem(question: "问题", answer: "- **[ ] 确认酒店**").displayAnswer.characters), "☐ 确认酒店")
        check("摘要显示：行内格式与高亮标记", String((SiriAIManager.displayText("定下 ==**路线图**==") ?? "").characters), "定下 路线图")
        let qa = SiriAIManager.qaInstructions(context: "预算 34,000 元")
        check("问答要求：只按文档回答、不自我介绍、附上文档", "\(qa.contains("Use only the content of the document")) \(qa.contains("Do not introduce yourself")) \(qa.contains("预算 34,000 元"))", "true true true")
        check("摘要解析：去掉 HTML 标签与脚注标记",
              SiriAIManager.parseSummaryBullets(from: "- 含 <kbd>⌘S</kbd> 和脚注[^1]").joined(), "含 ⌘S 和脚注")
    }

    // 双页对照表（LineMap）：无序列表（含 -）、有序列表、待办列表每一项各自对应原文行，不把整段列表并成一项
    do {
        let mdList = "# 标题\n\n- 第一项\n- 第二项\n- 第三项\n\n> 引用一\n> 引用二\n"
        let (_, map) = RichBridge.attributedWithLineMap(markdown: mdList, baseURL: nil)
        let lines = map.map { "\($0.line)..<\($0.endLine)" }.joined(separator: " ")
        check("双页对照表精确到每個列表项与引用行", lines, "0..<1 2..<3 3..<4 4..<5 6..<7 7..<8")
    }

    // 展示型 HTML 块：块里打的字保存时会丢，所以不接受；块外照常
    do {
        let src = "<p align=\"right\">右边</p>\n\n正文\n"
        let tv = makeView(src)
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        type(tv, "一")
        check("HTML 块中间打字不接受（不会显示了却保存不了）", "\(tv.string.contains("一")) \(md(tv) == src)", "false true")
        let body = (tv.string as NSString).range(of: "正文")
        tv.setSelectedRange(NSRange(location: NSMaxRange(body), length: 0))
        type(tv, "二")
        check("HTML 块外的正文照常打字", md(tv), "<p align=\"right\">右边</p>\n\n正文二\n")
    }
    do {
        let src = "<p align=\"right\">右边</p>\n\n正文\n"
        // 块后面一段的开头按退格：不把这段并进块里（并进去就会丢字）
        let tv = makeView(src)
        let body = (tv.string as NSString).range(of: "正文")
        tv.setSelectedRange(NSRange(location: body.location, length: 0))
        tv.deleteBackward(nil)
        tv.deleteBackward(nil)
        check("HTML 块后一段开头退格不并进块里", "\(md(tv) == src || md(tv).hasSuffix("</p>\n\n正文\n") || md(tv).hasSuffix("</p>\n正文\n")) \(tv.string.contains("正文"))", "true true")
        // 块尾回车：另起一段正文，接着打的字能保存
        let tv2 = makeView(src)
        let blockEnd = (tv2.string as NSString).range(of: "右边")
        tv2.setSelectedRange(NSRange(location: NSMaxRange(blockEnd), length: 0))
        tv2.insertNewline(nil)
        type(tv2, "新段")
        check("HTML 块尾回车后打字能保存", "\(md(tv2).contains("新段")) \(md(tv2).hasPrefix("<p align=\"right\">右边</p>"))", "true true")
        // 整块选中删除可以
        let tv3 = makeView(src)
        let whole = (tv3.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        tv3.setSelectedRange(whole)
        tv3.deleteBackward(nil)
        check("HTML 块可以整块删除", "\(md(tv3).contains("<p")) \(md(tv3).contains("正文"))", "false true")
    }

    // 网络图片：开关关闭时不下载，显示占位框；插入网址原样保存（? 后的参数不编码）
    do {
        UserDefaults.standard.set(false, forKey: RemoteImages.settingKey)
        let s = RichBridge.imageString(path: "https://example.com/badge.svg?style=flat", alt: "徽章", baseURL: nil)
        let cell = (s.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)?.attachmentCell as? PlaceholderAttachmentCell
        let longCell = PlaceholderAttachmentCell(label: String(repeating: "很长的说明文字", count: 30), font: .systemFont(ofSize: 12))
        let narrow = NSTextContainer(size: NSSize(width: 200, height: 1000))
        let frame = longCell.cellFrame(for: narrow, proposedLineFragment: NSRect(x: 0, y: 0, width: 200, height: 20), glyphPosition: .zero, characterIndex: 0)
        check("占位框太长时不超过文字区宽度", "\(frame.width <= 200)", "true")
        check("网络图片：开关关闭时显示占位框（整块）", "\(s.length) \(cell?.label ?? "无")", "1 网络图片未加载：徽章")
        check("网络图片：开关关闭时不下载", "\(RemoteImages.image(for: "https://example.com/x.png") == nil)", "true")
        check("网络图片：只认 http 和 https", "\(RemoteImages.url(for: "ftp://example.com/a.png") == nil) \(RemoteImages.url(for: "//example.com/a.png")?.scheme ?? "")", "true https")
        let tv = makeView("前文\n")
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        tv.insertImage(path: "https://example.com/a.png?x=1", alt: "a", encodePath: false)
        check("插入网络图片：网址原样保存、独占一行", md(tv), "前文\n\n![a](https://example.com/a.png?x=1)\n")
    }

    // 单页图片排版：正文里插入真实图片时独占一行居中，且后续打字自动落在图片下方新段落；多帧 GIF 动图正确识别帧数
    do {
        let pngDataUrl = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        let tv = makeView("前文\n")
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        tv.insertImage(path: pngDataUrl, alt: "示例图")
        type(tv, "后文")
        check("正文插入真实图片后独占一行且后续打字在下一段", md(tv), "前文\n\n![示例图](\(pngDataUrl))\n\n后文\n")

        let opened = makeView("![示例图](\(pngDataUrl))\n")
        let style = opened.textStorage!.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        check("独立图片段落居中显示", "\(style?.alignment == .center)", "true")

        // 用仓库里的真实 GIF 测试多帧动图识别（如有），或者从内存构建多帧 GIF 数据验证 ImageAttachmentCell
        let gifURL = URL(fileURLWithPath: "docs/images/demo.ja.gif")
        if FileManager.default.fileExists(atPath: gifURL.path), let gifImg = NSImage(contentsOf: gifURL) {
            let cell = ImageAttachmentCell(image: gifImg, size: NSSize(width: 200, height: 135))
            let rep = gifImg.representations.compactMap { $0 as? NSBitmapImageRep }.first
            let frames = (rep?.value(forProperty: .frameCount) as? Int) ?? 0
            check("多帧 GIF 动图帧数识别", "\(frames > 1) \(cell.cellSize().height == 143)", "true true")
        }
    }

    // 系统智能集成：全语言默认标题提取、Writing Tools 代码/公式保护、图片文字提取
    do {
        check("全语言命名：提取首个 Markdown 标题",
              DocumentTitleSuggester.fallbackTitle(from: "---\ntitle: ignore\n---\n\n# Weekly Summary / Week 12\n\nBody text.") ?? "",
              "Weekly Summary Week 12")
        check("全语言命名：无标题时取首行正文且跳过代码块",
              DocumentTitleSuggester.fallbackTitle(from: "```swift\nlet a = 1\n```\n\nこれは日本語の最初の段落です。") ?? "",
              "これは日本語の最初の段落です")
        check("全语言命名：过滤非法文件名字符",
              DocumentTitleSuggester.sanitizeFileName("  .a/b:c?d*  。") ?? "",
              "a b c d")

        // analyze 区分显式标题与正文首行，并只截取前段处理超长文档
        let analyzedHeading = DocumentTitleSuggester.analyze(from: "# 标题\n\n正文")
        check("全语言命名：analyze 识别显式标题", "\(analyzedHeading.title ?? "") \(analyzedHeading.hasHeading)", "标题 true")
        let longBody = "第一行正文\n\n" + String(repeating: "填充文本行\n", count: 1000)
        let analyzedBody = DocumentTitleSuggester.analyze(from: longBody)
        check("全语言命名：analyze 超长正文取首行且无显式标题", "\(analyzedBody.title ?? "") \(analyzedBody.hasHeading)", "第一行正文 false")

        // PendingDraftStore 一次性消费语义
        PendingDraftStore.store("# 草稿\n\n内容\n")
        check("快捷指令草稿缓存：第一次取出", PendingDraftStore.consume() ?? "", "# 草稿\n\n内容\n")
        check("快捷指令草稿缓存：第二次为空", PendingDraftStore.consume() ?? "nil", "nil")

        // 单页 Writing Tools 忽略范围：跳过代码块、行内代码、公式原文；普通正文不跳过
        let wtDoc = "普通正文 `code()` 结束\n\n```swift\nlet x = 1\n```\n\n$E=mc^2$\n"
        let tvWT = makeView(wtDoc)
        let storageWT = tvWT.textStorage!
        let ignoredRich = WritingToolsGuard.ignoredRanges(in: storageWT, enclosingRange: NSRange(location: 0, length: storageWT.length))
            .map { (storageWT.string as NSString).substring(with: $0.rangeValue) }
        check("WritingTools：单页排除代码块与行内代码",
              "\(ignoredRich.contains { $0.contains("code()") }) \(ignoredRich.contains { $0.contains("let x = 1") }) \(!ignoredRich.contains { $0.contains("普通正文") })",
              "true true true")

        // 双页源码 Writing Tools 忽略范围：YAML、围栏代码块、数学公式、行内代码均排除
        let srcWT = "---\nk: v\n---\n正文 `x` 结尾\n\n```py\nprint(1)\n```\n\n$$a+b$$\n"
        let nsWT = srcWT as NSString
        let ignoredSrc = WritingToolsGuard.ignoredRanges(inSource: srcWT, enclosingRange: NSRange(location: 0, length: nsWT.length))
            .map { nsWT.substring(with: $0.rangeValue) }
        check("WritingTools：双页排除 YAML、代码块、公式与行内代码",
              "\(ignoredSrc.contains { $0.contains("k: v") }) \(ignoredSrc.contains { $0.contains("print(1)") }) \(ignoredSrc.contains { $0.contains("$$a+b$$") }) \(ignoredSrc.contains { $0.contains("`x`") })",
              "true true true true")

        // Vision 图片文字识别（xcode-27 虚拟机中 Apple Vision 返回空，CI 通过环境变量跳过）
        let samplePDF = URL(fileURLWithPath: "packaging/samples/sample_scanned.pdf")
        if ProcessInfo.processInfo.environment["DROPMD_SKIP_VISION_SELFTEST"] != "1",
           FileManager.default.fileExists(atPath: samplePDF.path) {
            let ocrText = ImageTextExtractor.recognizeText(at: samplePDF) ?? ""
            check("Vision 图片文字提取", "\(ocrText.contains("DropMD"))", "true")
        }

        // 本机摘要分段与插入位置：跳过 YAML 头部与一级标题
        let shortChunks = SiriAIManager.splitIntoChunks("第一段\n\n第二段", maxChars: 2400)
        check("摘要分段：短文合并为单块", "\(shortChunks.count)", "1")
        let longChunks = SiriAIManager.splitIntoChunks((1...8).map { "第\($0)段内容：" + String(repeating: "测", count: 800) }.joined(separator: "\n\n"), maxChars: 1000)
        check("摘要分段：长文拆成多块且不丢段落", "\(longChunks.count > 1) \(longChunks.joined(separator: "\n\n").contains("第8段内容"))", "true true")

        check("摘要解析：剥离重复列表前缀",
              SiriAIManager.parseSummaryBullets(from: "- - 要点一\n* • 要点二").joined(separator: "|"),
              "要点一|要点二")

        // 保格式整篇翻译：只翻自然语言，代码、公式、YAML、链接地址、图片路径完全保留
        let transSrc = """
        ---
        title: Keep
        ---

        # 原标题

        你好 `keepCode()` 和 [链接](https://example.com)

        | 表头 | 列 |
        | --- | --- |
        | 单元格 | $x^2$ |

        ```swift
        let unchanged = true
        ```

        ![图](img/a.png)
        """
        let segs = MarkdownTranslator.extractSegments(from: transSrc)
        check("整篇翻译：排除代码、公式与 YAML",
              "\(!segs.contains { $0.text.contains("keepCode") }) \(!segs.contains { $0.text.contains("unchanged") }) \(!segs.contains { $0.text.contains("Keep") })",
              "true true true")
        var transMap: [String: String] = [:]
        for s in segs {
            switch s.text {
            case "原标题": transMap[s.id] = "Translated Heading"
            case "你好": transMap[s.id] = "Hello"
            case "链接": transMap[s.id] = "Link"
            case "表头": transMap[s.id] = "Header"
            case "单元格": transMap[s.id] = "Cell"
            default: break
            }
        }
        let transOut = MarkdownTranslator.applyTranslations(transMap, to: transSrc)
        check("整篇翻译：替换文字并保留所有格式与链接路径",
              "\(transOut.contains("# Translated Heading")) \(transOut.contains("Hello `keepCode()`")) \(transOut.contains("[Link](https://example.com)")) \(transOut.contains("| Header |")) \(transOut.contains("| Cell | $x^2$ |")) \(transOut.contains("let unchanged = true")) \(transOut.contains("![图](img/a.png)"))",
              "true true true true true true true")

        // 模型偏好与私有云策略
        if let defaults = UserDefaults(suiteName: "DropMD.AIModelPreference.tests.\(UUID())") {
            let key = AIModelPreference.storageKey
            check("模型偏好：未设置时自动", AIModelPreference.stored(in: defaults).rawValue, "auto")
            defaults.set("invalid", forKey: key)
            check("模型偏好：无效值回退自动", AIModelPreference.stored(in: defaults).rawValue, "auto")
            for explicit in [AIModelPreference.auto, .preferCloud, .onDeviceOnly] {
                defaults.set(explicit.rawValue, forKey: key)
                check("模型偏好：保留明确选择 \(explicit.rawValue)", AIModelPreference.stored(in: defaults).rawValue, explicit.rawValue)
            }
            defaults.removeObject(forKey: key)
        }
        check("模型策略：仅本机始终不用云", "\(SiriAIManager.shouldUsePrivateCloud(preference: .onDeviceOnly, contentLength: 50000))", "false")
        check("模型策略：优先私有云短文也用云", "\(SiriAIManager.shouldUsePrivateCloud(preference: .preferCloud, contentLength: 20))", "true")
        check("模型策略：自动短文用本机、长文用云",
              "\(SiriAIManager.shouldUsePrivateCloud(preference: .auto, contentLength: 800)) \(SiriAIManager.shouldUsePrivateCloud(preference: .auto, contentLength: 4000))",
              "false true")

        // @Generable 结构化小工具格式化纯函数
        let mdTable = SiriAIManager.formatMarkdownTable(
            headers: ["项目", "负责|人"],
            rows: [["发布", "张三", "多余列"], ["   ", "  "], ["测试"]]
        )
        check("表格转换格式化：转义竖线与对齐列数",
              mdTable,
              "| 项目 | 负责\\|人 |\n| --- | --- |\n| 发布 | 张三 |\n| 测试 |  |")
        check("表格转换格式化：空表头返回空串",
              SiriAIManager.formatMarkdownTable(headers: ["  "], rows: [["1"]]),
              "")

        let tasks = SiriAIManager.formatTaskList(["- [ ] 补写单测", "1. 补写单测", "* 整理发布说明", "  "])
        check("待办提取格式化：去重去空并统一语法",
              tasks,
              "- [ ] 补写单测\n- [ ] 整理发布说明")

        let yaml = SiriAIManager.formatYAMLFrontMatter(
            title: "DropMD: \"Beta\" 计划",
            date: "2026-11-24",
            tags: ["macOS", "Markdown", "macOS"],
            summary: "发布前\n最终检查"
        )
        check("文档属性格式化：安全转义引号与多行并去重标签",
              yaml,
              "---\ntitle: \"DropMD: \\\"Beta\\\" 计划\"\ndate: 2026-11-24\ntags:\n  - \"macOS\"\n  - \"Markdown\"\nsummary: \"发布前 最终检查\"\n---")

        let docNoYAML = "# 标题\n\n正文内容。\n"
        check("文档属性写入：无 YAML 时插入文档开头",
              SiriAIManager.upsertYAMLFrontMatter(yaml, into: docNoYAML),
              yaml + "\n\n# 标题\n\n正文内容。\n")

        let docWithYAML = "---\ntitle: \"Old\"\n---\n\n# 标题\n\n正文内容。\n"
        check("文档属性写入：已有 YAML 时替换不重复",
              SiriAIManager.upsertYAMLFrontMatter(yaml, into: docWithYAML),
              yaml + "\n\n# 标题\n\n正文内容。\n")
        let bom = "\u{FEFF}", crlfYAML = yaml.replacingOccurrences(of: "\n", with: "\r\n")
        let adjacentHTML = "\r\n<div>紧贴 YAML 的 HTML</div> \r\n\n  # 标题\n正文"
        check("文档属性写入：保留紧贴 raw、BOM、混合换行和文末无换行",
              SiriAIManager.upsertYAMLFrontMatter(yaml, into: bom + " ---\t\r\ntitle: Old\r\n  ...  " + adjacentHTML),
              bom + crlfYAML + adjacentHTML)
        let leadingBlank = "\r\n---\nnot YAML\n---\n\n尾端  \r\n\r\n"
        check("文档属性写入：YAML 必须在首行，保留正文首尾空白",
              SiriAIManager.upsertYAMLFrontMatter(yaml, into: bom + leadingBlank),
              bom + crlfYAML + "\r\n\r\n" + leadingBlank)
        check("文档属性写入：无闭合标记时不删除旧内容",
              SiriAIManager.upsertYAMLFrontMatter(yaml, into: "---\n原文"), yaml + "\n\n---\n原文")
        check("文档属性写入：文末仅有 YAML、没有换行",
              SiriAIManager.upsertYAMLFrontMatter(yaml, into: "---\nold: 1\n..."), yaml)

        // 文档问答上下文筛选：优先保留匹配关键词段落
        let qaParas = [
            "# 概览\n这是文档第一段引言。",
            "第二段讨论了颜色搭配与排版细节。",
            "第三段详细记录了发布版本号与打包签名密钥管理流程。",
            "第四段讨论了字体回退逻辑。",
        ].joined(separator: "\n\n")
        let qaCtx = SiriAIManager.prepareContextForQA(document: qaParas, question: "打包签名流程是什么？", maxChars: 65)
        check("文档问答上下文：优先命中包含问题关键词的段落",
              "\(qaCtx.contains("概览")) \(qaCtx.contains("打包签名"))",
              "true true")

        // IndexedDocumentStore 索引写入、搜索与去重
        let storeKey = "dropmd.test.indexedDocuments.\(ProcessInfo.processInfo.processIdentifier)"
        let tmpDocDir = FileManager.default.temporaryDirectory.appendingPathComponent("dropmd-index-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDocDir, withIntermediateDirectories: true)
        let f1 = tmpDocDir.appendingPathComponent("plan.md")
        let f2 = tmpDocDir.appendingPathComponent("notes.md")
        try? Data("ok".utf8).write(to: f1)
        try? Data("ok".utf8).write(to: f2)
        IndexedDocumentStore.upsert(
            IndexedDocumentRecord(path: f1.path, title: "发布计划", displayName: "plan.md", keywords: ["v1.1", "Beta"], excerpt: "下周发布 macOS 版本", updatedAt: Date()),
            key: storeKey
        )
        IndexedDocumentStore.upsert(
            IndexedDocumentRecord(path: f2.path, title: "随手记", displayName: "notes.md", keywords: ["想法"], excerpt: "记录界面细节", updatedAt: Date()),
            key: storeKey
        )
        IndexedDocumentStore.upsert(
            IndexedDocumentRecord(path: f1.path, title: "最新 Beta 发布计划", displayName: "plan.md", keywords: ["v1.1", "Beta"], excerpt: "确认发版清单", updatedAt: Date()),
            key: storeKey
        )
        let allIndexed = IndexedDocumentStore.allRecords(key: storeKey)
        let hitIndexed = IndexedDocumentStore.search("Beta 计划", key: storeKey)
        check("语义文档索引：按路径去重并支持关键词检索",
              "\(allIndexed.count) \(hitIndexed.count) \(hitIndexed.first?.title ?? "")",
              "2 1 最新 Beta 发布计划")
        UserDefaults.standard.removeObject(forKey: storeKey)
        try? FileManager.default.removeItem(at: tmpDocDir)
    }

    // 展示型 HTML 与 README 渲染与往返
    do {
        let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let readmeURL = rootURL.appendingPathComponent("README.zh-CN.md")
        if let readme = try? String(contentsOf: readmeURL, encoding: .utf8) {
            let rendered = RichBridge.attributed(markdown: readme, baseURL: rootURL)
            let ns = rendered.string as NSString

            var attachmentCount = 0
            rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { val, _, _ in
                if let cell = (val as? NSTextAttachment)?.attachmentCell as? ImageAttachmentCell, cell.image != nil {
                    attachmentCount += 1
                }
            }
            check("README 本机图片全部加载为真实附件", attachmentCount >= 7 ? "ok" : "count=\(attachmentCount)", "ok")

            let leakedTags = ["<div align=\"center\">", "</div>", "<p align=\"right\">", "<img src=", "<a href=", "&nbsp;", "<br>"]
            let leaked = leakedTags.filter { rendered.string.contains($0) }
            check("README 不出现展示型 HTML 源码标签", leaked.isEmpty ? "clean" : leaked.joined(separator: ","), "clean")

            let langRange = ns.range(of: "简体中文")
            let langAlign = langRange.location != NSNotFound
                ? (rendered.attribute(.paragraphStyle, at: langRange.location, effectiveRange: nil) as? NSParagraphStyle)?.alignment
                : nil
            check("README 右对齐导航栏段落对齐为 right", langAlign == .right ? "right" : String(describing: langAlign), "right")

            let titleRange = ns.range(of: "DropMD")
            let titleAlign = titleRange.location != NSNotFound
                ? (rendered.attribute(.paragraphStyle, at: titleRange.location, effectiveRange: nil) as? NSParagraphStyle)?.alignment
                : nil
            check("README 居中标题段落对齐为 center", titleAlign == .center ? "center" : String(describing: titleAlign), "center")

            let roundTrip = MarkdownCodec.serialize(RichBridge.blocks(from: rendered), preserving: readme)
            check("README 富文本往返保存完全无损", roundTrip == readme ? "exact" : "diff", "exact")

            // 模拟在某段正文（如“还没有赞助者”）里打字后保存，所有 HTML 块完整保留
            let tv = RichTextView(frame: NSRect(x: 0, y: 0, width: 720, height: 600))
            tv.baseURL = rootURL
            tv.textStorage?.setAttributedString(rendered)
            let targetRange = (tv.string as NSString).range(of: "还没有赞助者")
            if targetRange.location != NSNotFound {
                tv.setSelectedRange(NSRange(location: targetRange.location, length: 0))
                type(tv, "目前")
                let editedSaved = MarkdownCodec.serialize(RichBridge.blocks(from: tv.textStorage!), preserving: readme)
                let htmlIntact = editedSaved.contains("<p align=\"right\">")
                    && editedSaved.contains("<div align=\"center\">")
                    && editedSaved.contains("<img src=\"docs/images/icon.png\" width=\"112\" alt=\"DropMD 图标\">")
                    && editedSaved.contains("&nbsp;·&nbsp;")
                    && editedSaved.contains("目前还没有赞助者")
                check("README 局部编辑后所有展示型 HTML 完整保留", htmlIntact ? "ok" : "lost", "ok")
            } else {
                check("README 找到编辑锚点", "missing", "found")
            }
        } else {
            check("读取 README.zh-CN.md", "missing", "ok")
        }

        // RichHTML 边界与共用 HTML 实体解码测试
        let singleQuoteP = RichBridge.attributed(markdown: "<p align='center'>居中&#39;文字&#x2014;测试</p>\n", baseURL: nil)
        let sqAlign = (singleQuoteP.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment
        check("单引号 align='center' 且解数字实体", "\(sqAlign == .center) \(singleQuoteP.string.trimmingCharacters(in: .newlines))", "true 居中'文字—测试")

        let unpairedDiv = RichBridge.attributed(markdown: "<div align=\"center\">\n\n普通正文\n", baseURL: nil)
        check("未配对 <div align> 保持原样卡片不隐藏", "\(unpairedDiv.attribute(DMKey.raw, at: 0, effectiveRange: nil) != nil) \(unpairedDiv.string.hasPrefix("<div"))", "true true")

        let divWithTable = RichBridge.attributed(markdown: "<div align=\"center\">\n<table><tr><td>x</td></tr></table>\n</div>\n", baseURL: nil)
        check("含 <table> 的 HTML 块回退原样卡片", divWithTable.attribute(DMKey.raw, at: 0, effectiveRange: nil) != nil ? "raw" : "rendered", "raw")

        check("通用实体解码", MarkdownCodec.decodeHTMLEntities("A&amp;B &#39;C&#x2014;D&nbsp;E", nbspAsSpace: true), "A&B 'C—D E")
    }

    print(failures == 0 ? "全部通过" : "失败 \(failures) 项")
    if failures > 0 { exit(1) }
}

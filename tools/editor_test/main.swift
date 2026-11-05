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
        // 快速查看：大图缩小后再嵌入，小图不变；导出时大图保持原图
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2400, pixelsHigh: 1200, bitsPerSample: 8, samplesPerPixel: 3,
                                   hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 7200, bitsPerPixel: 24)!
        arc4random_buf(rep.bitmapData!, 7200 * 1200)   // 随机内容压不小，文件超过 512 KB
        let big = rep.representation(using: .png, properties: [:])!
        try? big.write(to: dir.appendingPathComponent("big.png"))
        let tag = #"<img src="big.png">"#
        let quick = HTMLExport.embedLocalImages(tag, base: dir, maxPixel: 1600)
        let b64 = quick.components(separatedBy: "base64,").last?.dropLast(2) ?? ""
        let shown = Data(base64Encoded: String(b64)).flatMap(NSBitmapImageRep.init(data:))
        check("快速查看缩小大图", "\(quick.hasPrefix("<img src=\"data:image/jpeg")) \(shown?.pixelsWide ?? 0)×\(shown?.pixelsHigh ?? 0)", "true 1600×800")
        check("快速查看不动小图", HTMLExport.embedLocalImages(html, base: dir, maxPixel: 1600), HTMLExport.embedLocalImages(html, base: dir))
        check("地址有编码的本机图片能显示", RichBridge.imageString(path: "big%2Epng", alt: "", baseURL: URL(fileURLWithPath: dir.path, isDirectory: true)).attribute(.attachment, at: 0, effectiveRange: nil) != nil ? "有" : "没有", "有")
        check("导出保持原图", HTMLExport.embedLocalImages(tag, base: dir) == "<img src=\"data:image/png;base64,\(big.base64EncodedString())\">" ? "原图" : "变了", "原图")
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
    print(failures == 0 ? "全部通过" : "失败 \(failures) 项")
    if failures > 0 { exit(1) }
}

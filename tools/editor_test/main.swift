// 单页编辑器的按键行为测试：在离屏的编辑区中模拟输入、回车、Tab、退格，检查得到的 Markdown。
import AppKit

/// 测试中不需要真正的编辑器窗口控制器（EditorAction.swift 引用了这个类型）
@MainActor final class EditorController { func perform(_ a: EditorAction) {} }

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
    // 脚注：正文里的编号是上标，文末说明行开头的编号不是
    do {
        let tv = makeView("正文[^1]\n\n[^1]: 说明\n")
        let s = tv.textStorage!, ns = tv.string as NSString
        let sup = { (loc: Int) in (s.attribute(.superscript, at: loc, effectiveRange: nil) as? Int) ?? 0 }
        check("脚注引用上标", "\(sup(2))", "1")
        check("脚注说明不上标", "\(sup(ns.range(of: "[^1]", options: .backwards).location))", "0")
        check("脚注往返", md(tv), "正文[^1]\n\n[^1]: 说明\n")
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

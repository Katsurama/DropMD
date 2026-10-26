import SwiftUI

/// 编辑器的所有命令。菜单、工具栏和“格式”面板都由这里生成，避免各处重复定义。
enum EditorAction: String, CaseIterable, Identifiable {
    // 文字样式
    case bold, italic, underline, strike, highlight, inlineCode, superscriptText, subscriptText, kbd
    // 段落样式
    case body, heading1, heading2, heading3, heading4, heading5, heading6, quote, codeBlock
    // 列表
    case bullet, numbered, task, outdent, indent
    // 插入
    case link, image, table, rule, details, callout, footnote, inlineMath, mathBlock, lineBreak, date, emoji
    // 导出
    case exportPDF, exportHTML

    var id: String { rawValue }

    /// 常用文字样式（格式面板第一行）
    static let textStyles: [EditorAction] = [.bold, .italic, .underline, .strike, .highlight, .inlineCode]
    /// 其他文字样式（格式面板第二行、菜单）
    static let moreTextStyles: [EditorAction] = [.superscriptText, .subscriptText, .kbd]
    static let paragraphStyles: [EditorAction] = [.body, .heading1, .heading2, .heading3, .heading4, .heading5, .heading6,
                                                  .quote, .codeBlock]
    static let lists: [EditorAction] = [.bullet, .numbered, .task, .outdent, .indent]
    /// 插入菜单的分组（按用途：图表、链接与注释、块、文字中）
    static let insertGroups: [[EditorAction]] = [
        [.image, .table],
        [.link, .footnote],
        [.details, .mathBlock, .rule],
        [.inlineMath, .date, .lineBreak, .emoji],
    ]

    var title: String {
        switch self {
        case .bold: return "粗体"
        case .italic: return "斜体"
        case .underline: return "下划线"
        case .strike: return "删除线"
        case .highlight: return "高亮"
        case .inlineCode: return "行内代码"
        case .superscriptText: return "上标"
        case .subscriptText: return "下标"
        case .kbd: return "键盘按键"
        case .body: return "正文"
        case .heading1: return "标题 1"
        case .heading2: return "标题 2"
        case .heading3: return "标题 3"
        case .heading4: return "标题 4"
        case .heading5: return "标题 5"
        case .heading6: return "标题 6"
        case .quote: return "引用"
        case .codeBlock: return "代码块"
        case .bullet: return "项目符号"
        case .numbered: return "编号"
        case .task: return "待办"
        case .outdent: return "减少缩进"
        case .indent: return "增加缩进"
        case .link: return "链接"
        case .image: return "图片"
        case .table: return "表格"
        case .rule: return "分隔线"
        case .details: return "折叠块"
        case .callout: return "提示框"
        case .date: return "今天的日期"
        case .emoji: return "表情与符号"
        case .footnote: return "脚注"
        case .inlineMath: return "行内公式"
        case .mathBlock: return "公式块"
        case .lineBreak: return "换行（不分段）"
        case .exportPDF: return "导出 PDF…"
        case .exportHTML: return "导出 HTML…"
        }
    }

    /// 菜单中的标题（需要弹出对话框的命令加“…”）
    var menuTitle: String {
        switch self {
        case .link, .image, .footnote, .inlineMath, .mathBlock, .emoji: return title + "…"
        default: return title
        }
    }

    var symbol: String {
        switch self {
        case .bold: return "bold"
        case .italic: return "italic"
        case .underline: return "underline"
        case .strike: return "strikethrough"
        case .highlight: return "highlighter"
        case .inlineCode: return "chevron.left.forwardslash.chevron.right"
        case .superscriptText: return "textformat.superscript"
        case .subscriptText: return "textformat.subscript"
        case .kbd: return "keyboard"
        case .body: return "text.alignleft"
        case .heading1, .heading2, .heading3, .heading4, .heading5, .heading6: return "textformat.size"
        case .quote: return "text.quote"
        case .codeBlock: return "curlybraces"
        case .bullet: return "list.bullet"
        case .numbered: return "list.number"
        case .task: return "checklist"
        case .outdent: return "decrease.indent"
        case .indent: return "increase.indent"
        case .link: return "link"
        case .image: return "photo"
        case .table: return "tablecells"
        case .rule: return "minus"
        case .details: return "chevron.right.square"
        case .callout: return "exclamationmark.bubble"
        case .date: return "calendar"
        case .emoji: return "face.smiling"
        case .footnote: return "note.text"
        case .inlineMath, .mathBlock: return "function"
        case .lineBreak: return "return"
        case .exportPDF: return "doc.richtext"
        case .exportHTML: return "globe"
        }
    }

    var shortcut: KeyboardShortcut? {
        switch self {
        case .bold: return KeyboardShortcut("b")
        case .italic: return KeyboardShortcut("i")
        case .underline: return KeyboardShortcut("u")
        case .strike: return KeyboardShortcut("x", modifiers: [.command, .shift])
        case .highlight: return KeyboardShortcut("h", modifiers: [.command, .shift])
        case .inlineCode: return KeyboardShortcut("c", modifiers: [.command, .option])
        case .superscriptText: return KeyboardShortcut("=", modifiers: [.command, .control])
        case .subscriptText: return KeyboardShortcut("-", modifiers: [.command, .control])
        case .kbd, .callout, .date, .emoji: return nil
        case .body: return KeyboardShortcut("0", modifiers: [.command, .option])
        case .heading1: return KeyboardShortcut("1", modifiers: [.command, .option])
        case .heading2: return KeyboardShortcut("2", modifiers: [.command, .option])
        case .heading3: return KeyboardShortcut("3", modifiers: [.command, .option])
        case .heading4: return KeyboardShortcut("4", modifiers: [.command, .option])
        case .heading5: return KeyboardShortcut("5", modifiers: [.command, .option])
        case .heading6: return KeyboardShortcut("6", modifiers: [.command, .option])
        case .quote: return KeyboardShortcut("'", modifiers: [.command, .shift])
        case .codeBlock: return KeyboardShortcut("c", modifiers: [.command, .shift, .option])
        case .bullet: return KeyboardShortcut("u", modifiers: [.command, .shift])
        case .numbered: return KeyboardShortcut("o", modifiers: [.command, .option])
        case .task: return KeyboardShortcut("l", modifiers: [.command, .shift])
        case .outdent: return KeyboardShortcut("[")
        case .indent: return KeyboardShortcut("]")
        case .link: return KeyboardShortcut("k")
        case .image: return KeyboardShortcut("k", modifiers: [.command, .shift])
        case .table: return KeyboardShortcut("t", modifiers: [.command, .option])
        case .details: return KeyboardShortcut("d", modifiers: [.command, .shift])
        case .footnote: return KeyboardShortcut("f", modifiers: [.command, .option])
        case .inlineMath: return KeyboardShortcut("m", modifiers: [.command, .option])
        case .mathBlock: return KeyboardShortcut("m", modifiers: [.command, .shift, .option])
        case .exportPDF: return KeyboardShortcut("p", modifiers: [.command, .option])
        case .exportHTML: return KeyboardShortcut("e", modifiers: [.command, .shift])
        case .lineBreak: return KeyboardShortcut(.return, modifiers: .shift)
        case .rule: return nil
        }
    }

    /// 段落样式命令对应的样式
    var paragraphKind: RichKind? {
        switch self {
        case .body: return .body
        case .heading1: return .heading(1)
        case .heading2: return .heading(2)
        case .heading3: return .heading(3)
        case .heading4: return .heading(4)
        case .heading5: return .heading(5)
        case .heading6: return .heading(6)
        case .quote: return .quote
        case .codeBlock: return .code("")
        default: return nil
        }
    }
}

/// 一组命令生成的菜单项
struct ActionMenuItems: View {
    let actions: [EditorAction]
    let editor: EditorController?

    var body: some View {
        ForEach(actions) { action in
            Button(action.menuTitle) { editor?.perform(action) }
                .keyboardShortcut(action.shortcut)
                .disabled(editor == nil)
        }
    }
}

import SwiftUI

/// 右侧的“格式”面板（参考 Pages 的“格式”检查器）：段落样式、文字样式、列表。
/// 插入类命令在工具栏和菜单“插入”中，这里不重复。
struct FormatInspector: View {
    let editor: EditorController
    @ObservedObject var selection: SelectionModel
    /// 单页时显示光标处的当前样式；双页时只提供按钮
    let isRich: Bool

    var body: some View {
        // 放得下时不用滚动区域：macOS 的滚动区域会在工具栏下方再多留一段工具栏高度，顶部空出一大块
        ViewThatFits(in: .vertical) {
            cards
            ScrollView { cards }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // 参考 Xcode / Pages 的检查器：小标题 + 分隔线分节，不用卡片边框
    private var cards: some View {
        VStack(alignment: .leading, spacing: 0) {
            section("段落样式") {
                VStack(spacing: 1) {
                    ForEach(EditorAction.paragraphStyles) { styleRow($0) }
                }
            }
            Divider().padding(.horizontal, 16)
            section("文字") {
                buttonGrid(EditorAction.textStyles + EditorAction.moreTextStyles)
            }
            Divider().padding(.horizontal, 16)
            section("列表与缩进") {
                buttonGrid(EditorAction.lists)
            }
        }
        .padding(.vertical, 4)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 组件

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func styleRow(_ action: EditorAction) -> some View {
        let selected = isRich && isCurrent(action)
        return Button { editor.perform(action) } label: {
            HStack {
                Text(action.title)
                    .font(previewFont(action))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let shortcut = action.shortcut {
                    Text(shortcut.displayText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                }
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 按钮统一排成每行 5 个，各卡片中的按钮大小相同、上下对齐
    private static let columns = 5

    private func buttonGrid(_ actions: [EditorAction]) -> some View {
        let rows = stride(from: 0, to: actions.count, by: Self.columns).map {
            Array(actions[$0..<min($0 + Self.columns, actions.count)])
        }
        return VStack(spacing: 6) {
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    ForEach(rows[i]) { styleButton($0) }
                    ForEach(0..<(Self.columns - rows[i].count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity).frame(height: 1)
                    }
                }
            }
        }
    }

    /// 系统标准的切换按钮：当前生效的样式显示为按下状态
    private func styleButton(_ action: EditorAction) -> some View {
        Toggle(isOn: Binding(get: { isRich && isActive(action) }, set: { _ in editor.perform(action) })) {
            Image(systemName: action.symbol)
                .frame(maxWidth: .infinity)
        }
        .toggleStyle(.button)
        .controlSize(.large)
        .help(action.title + (action.shortcut.map { "（\($0.displayText)）" } ?? ""))
        .accessibilityLabel(action.title)
    }

    // MARK: 状态

    private func isCurrent(_ action: EditorAction) -> Bool {
        if case .code = selection.state.kind { return action == .codeBlock }
        return action.paragraphKind == selection.state.kind
    }

    private func isActive(_ action: EditorAction) -> Bool {
        switch (action, selection.state.kind) {
        case (.bullet, .bullet), (.numbered, .ordered), (.task, .task): return true
        default: return selection.state.active.contains(action)
        }
    }

    private func previewFont(_ action: EditorAction) -> Font {
        switch action {
        case .heading1: return .title2.bold()
        case .heading2: return .title3.bold()
        case .heading3: return .headline
        case .heading4: return .subheadline.bold()
        case .heading5, .heading6: return .footnote.bold()
        case .quote: return .body.italic()
        case .codeBlock: return .system(.body, design: .monospaced)
        default: return .body
        }
    }
}

extension KeyboardShortcut {
    /// 快捷键的显示文字，如 ⌥⌘1
    var displayText: String {
        var t = ""
        if modifiers.contains(.control) { t += "⌃" }
        if modifiers.contains(.option) { t += "⌥" }
        if modifiers.contains(.shift) { t += "⇧" }
        if modifiers.contains(.command) { t += "⌘" }
        if key == .return { return t + "↩" }
        return t + String(key.character).uppercased()
    }
}

/// 工具栏中的段落样式菜单：显示光标处的样式（正文、标题 1…）
struct ParagraphStyleMenu: View {
    let editor: EditorController
    @ObservedObject var selection: SelectionModel
    /// 双页时不知道原文光标处的样式，只显示“样式”
    var isRich = true

    var body: some View {
        Menu {
            ForEach(EditorAction.paragraphStyles) { action in
                Button(action.title) { editor.perform(action) }
            }
        } label: {
            Text(currentTitle)
        }
        .fixedSize()
        .help("段落样式")
    }

    private var currentTitle: String {
        guard isRich else { return "样式" }
        if case .code = selection.state.kind { return EditorAction.codeBlock.title }
        return EditorAction.paragraphStyles.first { $0.paragraphKind == selection.state.kind }?.title ?? "正文"
    }
}

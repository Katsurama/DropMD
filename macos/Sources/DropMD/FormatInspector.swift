import SwiftUI

/// 右侧面板当前显示的独立栏目（同一时间只显示一个，互相替换）
enum InspectorPane: String {
    case none, format, outline, summary
}

/// 右侧独立面板：格式、目录或文章摘要（由工具栏各自独立按钮切换）。
/// 插入类命令在工具栏和菜单“插入”中，这里不重复。
struct FormatInspector: View {
    let pane: InspectorPane
    @ObservedObject var editor: EditorController
    @ObservedObject var selection: SelectionModel

    var body: some View {
        Group {
            switch pane {
            case .format:
                // 放得下时不用滚动区域：macOS 的滚动区域会在工具栏下方再多留一段工具栏高度，顶部空出一大块
                ViewThatFits(in: .vertical) {
                    cards
                    ScrollView { cards }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            case .outline:
                OutlineListView(editor: editor)   // 显示着才找标题
                    .onAppear { editor.outlineVisible = true }
                    .onDisappear { editor.outlineVisible = false }
            case .summary:
                SummaryInspectorView(editor: editor)
                    .onAppear { editor.generateDocumentSummary(force: false) }
                    .onDisappear { editor.cancelDocumentSummary() }
            case .none:
                EmptyView()
            }
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

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
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
        let selected = selection.richFocused && isCurrent(action)
        return Button { editor.perform(action) } label: {
            HStack {
                Text(action.title)
                    .font(previewFont(action))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let shortcut = action.shortcut {
                    Text(shortcut.displayText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(selected ? Color.accentColor.opacity(0.8) : Color.secondary)
                }
            }
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
        Toggle(isOn: Binding(get: { selection.richFocused && isActive(action) }, set: { _ in editor.perform(action) })) {
            Image(systemName: action.symbol)
                .frame(maxWidth: .infinity)
        }
        .toggleStyle(.button)
        .controlSize(.large)
        .help(action.title + (action.shortcut.map { String(localized: "（\($0.displayText)）") } ?? ""))
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

/// 文档目录列表（按标题层级缩进，点击跳转）
private struct OutlineListView: View {
    @ObservedObject var editor: EditorController

    var body: some View {
        if editor.headings.isEmpty {
            Text("暂无标题")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(editor.headings) { heading in
                        OutlineRowView(heading: heading) {
                            editor.jumpToHeading(heading)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
    }
}

private struct OutlineRowView: View {
    let heading: DocumentHeading
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(heading.title)
                .font(heading.level == 1 ? .callout.weight(.semibold) : heading.level == 2 ? .callout.weight(.medium) : .callout)
                .foregroundStyle(heading.level <= 2 ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, CGFloat(max(0, heading.level - 1) * 12) + 8)
                .padding(.trailing, 8)
                .padding(.vertical, 5)
                .background(hovered ? Color.primary.opacity(0.06) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(heading.title)
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

    var body: some View {
        Menu {
            ForEach(EditorAction.paragraphStyles) { action in
                Button(action.title) { editor.perform(action) }
            }
        } label: {
            Text(currentTitle)
        }
        .fixedSize()
        .help("设置段落样式")
    }

    private var currentTitle: String {
        guard selection.richFocused else { return String(localized: "样式") }
        if case .code = selection.state.kind { return EditorAction.codeBlock.title }
        return EditorAction.paragraphStyles.first { $0.paragraphKind == selection.state.kind }?.title ?? String(localized: "正文")
    }
}

/// 侧边栏“摘要”标签页：本机 Siri AI 自动生成整篇文章的要点摘要
private struct SummaryInspectorView: View {
    @ObservedObject var editor: EditorController
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 8) {
                Button(copied ? String(localized: "已复制") : String(localized: "复制")) {
                    let text = editor.summaryBullets.map { "- \($0)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                }
                .disabled(editor.isSummarizing || editor.summaryBullets.isEmpty)

                Spacer()

                Button("重新生成") {
                    editor.generateDocumentSummary(force: true)
                }
                .disabled(editor.isSummarizing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        if editor.isSummarizing {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                Text("正在生成文章摘要…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        } else if let error = editor.summaryError {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("重试") {
                    editor.generateDocumentSummary(force: true)
                }
            }
            .padding(20)
        } else if editor.summaryBullets.isEmpty {
            Text("暂无摘要内容")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(24)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(editor.summaryBullets.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 6) {
                            Text(verbatim: "•")
                                .foregroundStyle(.secondary)
                            Text(verbatim: item)
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(14)
            }
        }
    }
}

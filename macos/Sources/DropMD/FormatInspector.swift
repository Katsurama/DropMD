import SwiftUI

/// 右侧面板当前显示的独立栏目（同一时间只显示一个，互相替换）
enum InspectorPane: String {
    case none, format, outline, summary
}

/// 右侧独立面板：格式、目录或文章摘要（由工具栏各自独立按钮切换）。
/// 插入类命令在工具栏和菜单“插入”中，这里不重复。
struct FormatInspector: View {
    let pane: InspectorPane
    let editor: EditorController   // 不观察：字数等每按一个键都变，这里用不到；目录、摘要各自观察
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
            case .none:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor).ignoresSafeArea(.container, edges: .top))
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
                .font(heading.level == 1 ? .system(size: 13.5, weight: .semibold) : heading.level == 2 ? .system(size: 13.5, weight: .medium) : .system(size: 13.5))
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
            // 宽度按最长的样式名固定：切换样式时按钮不变宽，不压到旁边的按钮组
            ZStack {
                ForEach(Self.allTitles, id: \.self) { Text($0).hidden() }
                Text(currentTitle)
            }
        }
        .fixedSize()
        .help("段落样式")
        .accessibilityLabel("段落样式")
    }

    private static var allTitles: [String] {
        [String(localized: "样式")] + EditorAction.paragraphStyles.map(\.title)
    }

    private var currentTitle: String {
        guard selection.richFocused else { return String(localized: "样式") }
        if case .code = selection.state.kind { return EditorAction.codeBlock.title }
        return EditorAction.paragraphStyles.first { $0.paragraphKind == selection.state.kind }?.title ?? String(localized: "正文")
    }
}

/// 侧边栏“摘要”标签页：上半区文章摘要（或所选内容摘要），下半区 Apple Intelligence 问答（支持中间分隔线上下拖动）
private struct SummaryInspectorView: View {
    @ObservedObject var editor: EditorController
    /// 0 表示没拖过：摘要和对话区域一样高。旧的 summaryTopFraction 多是点到分隔线时误存的，不再沿用
    @AppStorage("summarySplitFraction") private var topFraction: Double = 0
    private static let dividerHeight = 9.0
    private static let inputBarHeight = 54.0   // 底部提问输入框连上下留白
    @State private var copied = false
    @State private var questionText = ""
    @State private var dividerHovered = false
    @FocusState private var questionFocused: Bool

    var body: some View {
        GeometryReader { geo in
            let totalH = max(geo.size.height, 1)
            let topH = clampedTopHeight(totalH)
            VStack(spacing: 0) {
                summarySection
                    .frame(height: topH)
                ZStack {
                    Rectangle()
                        .fill(Color(nsColor: RichStyle.lineColor))
                        .frame(height: 1)
                        .padding(.horizontal, 16)
                    if dividerHovered {
                        Capsule()
                            .fill(Color.secondary.opacity(0.45))
                            .frame(width: 28, height: 3)
                    }
                }
                .frame(height: Self.dividerHeight)
                .contentShape(Rectangle())
                .onHover { dividerHovered = $0 }
                .overlay(VerticalSplitHandle(
                    onDragDelta: { deltaY in
                        let h = max(geo.size.height, 1)
                        let cur = clampedTopHeight(h)
                        let next = clampedTopHeight(h, proposed: cur + deltaY)
                        topFraction = next / h
                    },
                    onDoubleClick: { topFraction = 0 }
                ))
                .zIndex(1)
                qaSection
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func clampedTopHeight(_ totalHeight: Double, proposed: Double? = nil) -> Double {
        let minTop = 110.0
        let minBottom = 160.0
        let even = (totalHeight - Self.dividerHeight - Self.inputBarHeight) / 2
        // 不取整：慢慢拖时每次不到半点，取整后就永远拖不动
        let raw = proposed ?? (topFraction > 0 ? totalHeight * topFraction : even)
        if totalHeight <= minTop + minBottom {
            return max(40.0, min((totalHeight * 0.45).rounded(), totalHeight - 40.0))
        }
        return min(max(raw, minTop), totalHeight - minBottom)
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("文章摘要")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                if editor.summaryIsSelection {
                    Text("所选内容")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.14), in: Capsule())
                }
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    InspectorIconButton(
                        symbol: copied ? "checkmark" : "doc.on.doc",
                        helpText: copied ? String(localized: "已复制") : String(localized: "复制"),
                        disabled: editor.isSummarizing || editor.summaryBullets.isEmpty
                    ) {
                        let text = editor.summaryBullets.map { "- \($0)" }.joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        copied = true
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            copied = false
                        }
                    }

                    InspectorIconButton(
                        symbol: "arrow.clockwise",
                        helpText: String(localized: "重新生成"),
                        disabled: editor.isSummarizing
                    ) {
                        editor.generateDocumentSummary(force: true)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            summaryContentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var summaryContentArea: some View {
        if editor.isSummarizing {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在生成文章摘要…")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
        } else if let error = editor.summaryError {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                Text(error)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("重试") {
                    editor.generateDocumentSummary(force: true)
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
        } else if editor.summaryBullets.isEmpty {
            Text("暂无摘要内容")
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(Array(editor.summaryBullets.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 7) {
                            Text(verbatim: "•")
                                .font(.system(size: 14.5))
                                .foregroundStyle(.secondary)
                            Text(SiriAIManager.displayText(item) ?? AttributedString(item))
                                .font(.system(size: 14.5))
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
    }

    private var qaSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(verbatim: "Apple Intelligence")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if !editor.qaMessages.isEmpty {
                    InspectorIconButton(
                        symbol: "trash",
                        helpText: String(localized: "清空对话"),
                        disabled: false
                    ) {
                        editor.clearDocumentQA()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)

            if editor.qaMessages.isEmpty {
                Text("可针对当前文档内容提问。")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(16)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(editor.qaMessages) { item in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Spacer(minLength: 24)
                                        Text(verbatim: item.question)
                                            .font(.system(size: 14.5))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                            .textSelection(.enabled)
                                    }
                                    if item.isLoading {
                                        HStack(spacing: 6) {
                                            ProgressView().controlSize(.small)
                                            Text("正在思考…")
                                                .font(.system(size: 13.5))
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(.top, 2)
                                    } else {
                                        Text(item.displayAnswer)
                                            .font(.system(size: 14.5))
                                            .lineSpacing(4)
                                            .foregroundStyle(item.isError ? Color.secondary : Color.primary)
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .id(item.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    .onChange(of: editor.qaMessages.last?.answer) { _, _ in
                        if let lastID = editor.qaMessages.last?.id {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(lastID, anchor: .bottom)
                            }
                        }
                    }
                }
            }

            let canSend = !editor.isAnsweringQA && !questionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            HStack(spacing: 8) {
                TextField("针对本文提问…", text: $questionText)
                    .font(.system(size: 14))
                    .textFieldStyle(.plain)
                    .focused($questionFocused)
                    .disabled(editor.isAnsweringQA)
                    .onSubmit(submitQuestion)

                Button(action: submitQuestion) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(canSend ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("发送")
                .accessibilityLabel("发送")
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        questionFocused ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.12),
                        lineWidth: questionFocused ? 1.5 : 1
                    )
            )
            .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 14)
        }
    }

    private func submitQuestion() {
        let q = questionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !editor.isAnsweringQA else { return }
        questionText = ""
        editor.askDocumentQuestion(q)
    }
}

/// 侧边栏标题行右侧轻按钮（带悬停圆形底色）
private struct InspectorIconButton: View {
    let symbol: String
    let helpText: String
    let disabled: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(disabled ? .quaternary : hovered ? .primary : .secondary)
                .frame(width: 24, height: 24)
                .background(hovered && !disabled ? Color.primary.opacity(0.08) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovered = $0 }
        .help(helpText)
        .accessibilityLabel(helpText)
    }
}

/// 上下分区中间的拖动条：鼠标移上去变成上下箭头，拖动实时回报垂直位移，双击恢复默认比例
private struct VerticalSplitHandle: NSViewRepresentable {
    var onDragDelta: (Double) -> Void
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> HandleView { HandleView() }
    func updateNSView(_ view: HandleView, context: Context) {
        view.onDragDelta = onDragDelta
        view.onDoubleClick = onDoubleClick
    }

    final class HandleView: NSView {
        var onDragDelta: ((Double) -> Void)?
        var onDoubleClick: (() -> Void)?
        private var lastWindowY: Double = 0

        override init(frame: NSRect) {
            super.init(frame: frame)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
        }
        required init?(coder: NSCoder) { fatalError() }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
        override func cursorUpdate(with event: NSEvent) { NSCursor.resizeUpDown.set() }
        override func hitTest(_ point: NSPoint) -> NSView? {
            frame.contains(point) ? self : nil
        }
        override func mouseDown(with event: NSEvent) {
            lastWindowY = event.locationInWindow.y
            if event.clickCount == 2 { onDoubleClick?() }
        }
        override func mouseDragged(with event: NSEvent) {
            NSCursor.resizeUpDown.set()
            let currentY = event.locationInWindow.y
            let deltaY = lastWindowY - currentY
            lastWindowY = currentY
            if abs(deltaY) > 0 {
                onDragDelta?(deltaY)
            }
        }
    }
}

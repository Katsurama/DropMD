import AppKit
import SwiftUI
import WebKit

// MARK: - 双页：原文编辑区

/// 基于 NSTextView（TextKit 1）的 Markdown 源码编辑区，带语法高亮。
struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    let controller: EditorController
    var isActive = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let tv = NSTextView(frame: .zero, textContainer: container)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 28, height: 24)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.typingAttributes = MarkdownHighlighter.baseAttributes
        tv.string = text
        tv.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = tv
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.didScroll(_:)),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)

        controller.textView = tv
        if let storage = tv.textStorage { MarkdownHighlighter.highlight(storage) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        scroll.isHidden = !isActive
        guard isActive, let tv = scroll.documentView as? NSTextView else {
            context.coordinator.wasActive = false
            return
        }
        controller.textView = tv
        // 仅当外部修改了文本（单页中的编辑、“恢复到上一版本”）时才整体替换
        if !context.coordinator.isEditing, tv.string != text {
            let sel = tv.selectedRange()
            tv.string = text
            tv.setSelectedRange(NSRange(location: min(sel.location, (text as NSString).length), length: 0))
            controller.scheduleHighlight()
        }
        if !context.coordinator.wasActive {
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
        context.coordinator.wasActive = true
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        // 修复：窗口关闭后仍在接收滚动通知
        NotificationCenter.default.removeObserver(coordinator, name: NSView.boundsDidChangeNotification,
                                                  object: scroll.contentView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextView
        var isEditing = false
        var wasActive = false

        init(_ parent: MarkdownTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            isEditing = true
            parent.text = tv.string
            isEditing = false
            MainActor.assumeIsolated { parent.controller.scheduleHighlight() }
        }

        @objc func didScroll(_ note: Notification) {
            MainActor.assumeIsolated { parent.controller.syncScroll() }
        }
    }
}

// MARK: - 预览区

/// WKWebView 预览：加载 App 内置的 preview.html（markdown-it + KaTeX），
/// 页面的内容安全策略禁止任何网络请求。
struct PreviewView: NSViewRepresentable {
    let controller: EditorController

    func makeCoordinator() -> Coordinator { Coordinator(controller) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent() // 不保存 Cookie、缓存等任何网页数据
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        controller.attachWebView(webView)
        if let url = EditorController.previewURL {
            // 允许读取本机文件，以便显示文档中以相对路径引用的本地图片
            webView.loadFileURL(url, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let controller: EditorController

        init(_ controller: EditorController) { self.controller = controller }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated { controller.previewDidLoad() }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.cancel) }
            // 只允许加载预览页面本身（包括脚注等页内锚点跳转）
            if url.isFileURL, url.path == EditorController.previewURL?.path {
                return decisionHandler(.allow)
            }
            if action.navigationType == .linkActivated {
                if url.isFileURL {
                    let ext = url.pathExtension.lowercased()
                    if ["md", "markdown", "mdown"].contains(ext) {
                        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
                    } else {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    // 用户点击链接时，用默认浏览器打开（预览本身不联网）
                    NSWorkspace.shared.open(url)
                }
            }
            decisionHandler(.cancel)
        }
    }
}

// MARK: - 编辑器窗口

enum EditorMode: String {
    case rich, source
}

struct EditorView: View {
    @Binding var document: MarkdownDocument
    let fileURL: URL?

    @StateObject private var editor = EditorController()
    @AppStorage("editorMode") private var mode: EditorMode = .rich
    @AppStorage("showInspector") private var showInspector = true
    /// 双页在窗口打开后于后台预先加载，第一次切换也不卡
    @State private var sourceLoaded = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // 单页延伸到工具栏下方（与 Pages 相同），不留一条分隔带
                RichTextEditor(text: $document.text, baseURL: fileURL?.deletingLastPathComponent(),
                               controller: editor, isActive: mode == .rich)
                    .ignoresSafeArea(.container, edges: .top)
                // 双页从工具栏下方开始，中间的分隔线不穿过工具栏
                if sourceLoaded || mode == .source {
                    sourcePane
                        .opacity(mode == .source ? 1 : 0)
                        .allowsHitTesting(mode == .source)
                }
            }
            statusBar
        }
        // 最小宽度留得小一些：打开“格式”面板时从编辑区分出空间，窗口不变大
        .frame(minWidth: 420, minHeight: 360)
        .inspector(isPresented: $showInspector) {
            FormatInspector(editor: editor, selection: editor.selection, isRich: mode == .rich)
                .inspectorColumnWidth(min: 240, ideal: 260, max: 340)
        }
        .onAppear {
            editor.fileURL = fileURL
            editor.isRichMode = mode == .rich
            editor.textChanged(document.text)
        }
        .task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            sourceLoaded = true
        }
        .onChange(of: document.text) { _, newValue in editor.textChanged(newValue) }
        .onChange(of: fileURL) { _, newValue in
            editor.fileURL = newValue
            editor.renderPreview()
        }
        .onChange(of: mode) { _, newValue in
            editor.isRichMode = newValue == .rich
            if newValue == .source { editor.textChanged(document.text) }
        }
        .focusedSceneObject(editor)
        .focusedSceneValue(\.editorModeSwitch, { newValue in modeBinding.wrappedValue = newValue })
        .focusedSceneValue(\.inspectorToggle, { showInspector.toggle() })
        .toolbar { toolbarContent }
        .hidesToolbarTitle()
        .onReceive(NotificationCenter.default.publisher(for: .showUpdates)) { _ in openWindow(id: "updates") }
    }

    /// 切换视图前，先把单页中尚未写回的修改写回文档
    private var modeBinding: Binding<EditorMode> {
        Binding(get: { mode }, set: { newValue in
            if mode == .rich { editor.flushPendingEdits() }
            sourceLoaded = true
            mode = newValue
        })
    }

    private var sourcePane: some View {
        // 左右各占一半，中间一条细线（深色时为白色，与单页的分隔线一致）
        HStack(spacing: 0) {
            MarkdownTextView(text: $document.text, controller: editor, isActive: mode == .source)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle()
                .fill(Color(nsColor: RichStyle.lineColor))
                .frame(width: 1)
            PreviewView(controller: editor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var statusBar: some View {
        // 只显示文件名和字数；鼠标停在文件名上显示完整路径
        HStack(spacing: 10) {
            Text(fileURL?.lastPathComponent ?? "尚未保存")
                .lineLimit(1)
                .truncationMode(.middle)
                .help(fileURL?.path ?? "")
            languageMenu
            Spacer()
            Text(editor.stats)
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(Color(nsColor: RichStyle.lineColor).opacity(0.5)).frame(height: 1) }
    }

    /// 文档语言：决定汉字用中文、日文还是韩文的写法
    private var languageMenu: some View {
        Menu {
            Picker("语言", selection: $editor.language) {
                ForEach(DocLanguage.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(editor.language == .auto ? "自动（\(editor.effectiveLanguage.title)）" : editor.language.title)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("文档语言：决定汉字用中文、日文还是韩文的写法")
    }

    // MARK: 工具栏（系统标准按钮，适配 Liquid Glass）

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("显示方式", selection: modeBinding) {
                Label("单页", systemImage: "doc.richtext").tag(EditorMode.rich)
                Label("双页", systemImage: "rectangle.split.2x1").tag(EditorMode.source)
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleAndIcon)
            .fixedSize()
            .help("单页（⌘1） / 双页（⌘2）")
        }
        // 中间：段落样式 | 文字样式 | 列表 | 插入（参考 Pages，常用命令一眼可见）
        // 每组是一个单独的工具栏项，Liquid Glass 下各自显示为一个小胶囊
        ToolbarItem(placement: .principal) {
            ParagraphStyleMenu(editor: editor, selection: editor.selection, isRich: mode == .rich)
        }
        ToolbarItem(placement: .principal) { toolbarGroup([.bold, .italic, .underline]) }
        ToolbarItem(placement: .principal) { toolbarGroup([.bullet, .numbered, .task]) }
        ToolbarItem(placement: .principal) {
            HStack(spacing: 0) {
                toolbarGroup([.table, .image, .link])
                insertMoreMenu
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { openWindow(id: "converter") } label: { Label("转换文件", systemImage: "arrow.down.doc") }
                .help("转换为 Markdown")
            Menu {
                Button(EditorAction.exportPDF.title) { editor.perform(.exportPDF) }
                Button(EditorAction.exportHTML.title) { editor.perform(.exportHTML) }
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .help("导出 PDF / HTML")
            Toggle(isOn: $showInspector) { Label("格式", systemImage: "paintbrush") }
                .help("格式面板（⌥⌘I）")
        }
    }

    /// 工具栏中的一组按钮（显示为一个整体）
    private func toolbarGroup(_ actions: [EditorAction]) -> some View {
        ControlGroup {
            ForEach(actions) { action in
                Button { editor.perform(action) } label: { Label(action.title, systemImage: action.symbol) }
                    .help(action.title + (action.shortcut.map { "（\($0.displayText)）" } ?? ""))
            }
        }
        .controlGroupStyle(.navigation)
    }

    /// “+”菜单：工具栏上没有的插入命令，分组与菜单栏“插入”相同
    private var insertMoreMenu: some View {
        Menu {
            ForEach(Array(EditorAction.insertGroups.enumerated()), id: \.offset) { i, group in
                let rest = group.filter { ![.image, .table, .link].contains($0) }
                if !rest.isEmpty {
                    Divider()
                    if group.contains(.details) {
                        Menu("提示框") {
                            ForEach(MDCallout.allCases, id: \.self) { c in Button(c.title) { editor.callout(c) } }
                        }
                        Menu("代码块") {
                            Button("纯文本") { editor.codeBlock() }
                            Divider()
                            ForEach(codeLanguages, id: \.self) { lang in Button(lang) { editor.codeBlock(lang) } }
                        }
                    }
                    ForEach(rest) { action in Button(action.menuTitle) { editor.perform(action) } }
                }
            }
        } label: {
            Label("插入", systemImage: "plus")
        }
        .help("插入")
    }
}

private extension View {
    /// 工具栏中不显示文件名（文件名在底部状态栏），中间的按钮才能在窗口正中
    @ViewBuilder
    func hidesToolbarTitle() -> some View {
        if #available(macOS 15.0, *) {
            toolbar(removing: .title)
                // 工具栏用系统的半透明背景（与 Xcode 相同），内容滚到下面时模糊显示
                .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        } else {
            self
        }
    }
}

/// 代码块可选的语言（用于导出和其他编辑器中的语法高亮）
let codeLanguages = ["swift", "python", "javascript", "typescript", "java", "c", "cpp", "csharp", "go", "rust",
                     "html", "css", "json", "yaml", "sql", "bash", "markdown", "mermaid"]

/// 菜单栏“显示 → 单页 / 双页”用来切换当前窗口的显示方式
struct EditorModeSwitchKey: FocusedValueKey {
    typealias Value = (EditorMode) -> Void
}

/// 菜单栏“显示 → 显示/隐藏格式面板”
struct InspectorToggleKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var editorModeSwitch: ((EditorMode) -> Void)? {
        get { self[EditorModeSwitchKey.self] }
        set { self[EditorModeSwitchKey.self] = newValue }
    }

    var inspectorToggle: (() -> Void)? {
        get { self[InspectorToggleKey.self] }
        set { self[InspectorToggleKey.self] = newValue }
    }
}

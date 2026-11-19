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
            // 整篇换掉后，左边以前的撤销记录按旧位置改字会把文档改乱（单页重排时也是这样清的）
            if let storage = tv.textStorage { tv.undoManager?.removeAllActions(withTarget: storage) }
            tv.setSelectedRange(NSRange(location: min(sel.location, (text as NSString).length), length: 0))
            controller.scheduleHighlight()
            controller.sourceTextReplaced()
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

        func textViewDidChangeSelection(_ notification: Notification) {
            MainActor.assumeIsolated { parent.controller.syncCursor() }
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
    /// 双页时左边原文占的比例：每次打开都从正中开始，拖动中间的分隔线调整
    @State private var splitFraction = 0.5
    /// 双页在窗口打开后于后台预先加载，第一次切换也不卡
    @State private var sourceLoaded = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // “格式”面板不用系统的 .inspector：它会让工具栏中间的按钮只按编辑区居中，打开面板时偏左
        HStack(spacing: 0) {
            editorColumn
            if showInspector {
                Rectangle()
                    .fill(Color(nsColor: RichStyle.lineColor))
                    .frame(width: 1)
                FormatInspector(editor: editor, selection: editor.selection, isRich: mode == .rich)
                    .frame(width: 260)
            }
        }
        // 最小宽度留得小一些：打开“格式”面板时从编辑区分出空间，窗口不变大
        .frame(minWidth: 420, minHeight: 360)
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
        .onReceive(NotificationCenter.default.publisher(for: .showUpdates)) { _ in SettingsPage.open(.updates, openSettings) }
        .background(WindowSizeKeeper())
    }

    private var editorColumn: some View {
        VStack(spacing: 0) {
            ZStack {
                // 网页预览不显示：只在后台用来导出 HTML / PDF
                if sourceLoaded || mode == .source {
                    PreviewView(controller: editor)
                        .opacity(0)
                        .allowsHitTesting(false)
                }
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        // 双页：左边原文，右边就是单页编辑区（同一个，两边都能改、实时同步）
                        if sourceLoaded || mode == .source {
                            MarkdownTextView(text: $document.text, controller: editor, isActive: mode == .source)
                                .frame(width: mode == .source ? sourceWidth(geo.size.width) : 0)
                                .frame(maxHeight: .infinity)
                                .opacity(mode == .source ? 1 : 0)
                                .allowsHitTesting(mode == .source)
                            if mode == .source {
                                Rectangle()
                                    .fill(Color(nsColor: RichStyle.lineColor))
                                    .frame(width: 1)
                                    // 线只有 1 点宽，能拖的范围左右各加宽 4 点
                                    .overlay(SplitHandle(
                                        onDrag: { x in
                                            let left = geo.frame(in: .global).minX
                                            splitFraction = clampedFraction((x - left) / max(geo.size.width, 1), width: geo.size.width)
                                        },
                                        onDoubleClick: { splitFraction = 0.5 }
                                    ).frame(width: 9))
                                    .zIndex(1)
                            }
                        }
                        // 单页延伸到工具栏下方（与 Pages 相同），不留一条分隔带
                        RichTextEditor(text: $document.text, baseURL: fileURL?.deletingLastPathComponent(), controller: editor)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .ignoresSafeArea(.container, edges: .top)
                    }
                }
            }
            statusBar
        }
    }

    /// 两边最窄各留 240 点；窗口太窄时各占一半
    private func clampedFraction(_ f: Double, width: Double) -> Double {
        let minF = 240 / width
        guard minF < 0.5 else { return 0.5 }
        return min(max(f, minF), 1 - minF)
    }

    private func sourceWidth(_ width: Double) -> Double {
        (width * clampedFraction(splitFraction, width: width)).rounded()
    }

    /// 切换视图前，先把单页中尚未写回的修改写回文档
    private var modeBinding: Binding<EditorMode> {
        Binding(get: { mode }, set: { newValue in
            if mode == .rich { editor.flushPendingEdits() }
            sourceLoaded = true
            mode = newValue
        })
    }

    private var statusBar: some View {
        // 只显示文件名和字数；鼠标停在文件名上显示完整路径
        HStack(spacing: 10) {
            Text(fileURL?.lastPathComponent ?? String(localized: "尚未保存"))
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
            Text(editor.language.title)
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
                // 不用“方框加向上箭头”：那是系统“分享”的图标，放在这里会被当成分享
                Label("导出", systemImage: "doc.badge.arrow.up")
            }
            .help("导出 PDF / HTML")
            // 苹果的分享面板（隔空投送、邮件、信息…）：分享这个 .md 文件；新文档还没存过、没有文件时不能分享
            Button { editor.share() } label: { Label("分享", systemImage: "square.and.arrow.up") }
                .disabled(fileURL == nil)
                .help(fileURL == nil ? "保存后才能分享" : "分享")
            Toggle(isOn: $showInspector) { Label("格式", systemImage: "paintbrush") }
                .help("格式面板（⌥⌘I）")
        }
    }

    /// 工具栏中的一组按钮（显示为一个整体）
    private func toolbarGroup(_ actions: [EditorAction]) -> some View {
        ControlGroup {
            ForEach(actions) { action in
                Button { editor.perform(action) } label: { Label(action.title, systemImage: action.symbol) }
                    .help(action.title + (action.shortcut.map { String(localized: "（\($0.displayText)）") } ?? ""))
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

/// 文档窗口用你最后一次拉好的大小打开（第一次用 980 × 660）。
/// 系统重新打开上次的窗口时会沿用当时的大小（比如铺满屏幕），这里统一改回记住的大小，只用调一次。
struct WindowSizeKeeper: NSViewRepresentable {
    static let key = "editorWindowSize"

    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Probe: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, observer == nil else { return }
            // 等系统恢复完窗口位置再改大小
            // 等系统恢复完窗口位置再改大小；全屏的窗口不动
            DispatchQueue.main.async { if !window.styleMask.contains(.fullScreen) { WindowSizeKeeper.apply(to: window) } }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { note in
                guard let w = note.object as? NSWindow else { return }
                UserDefaults.standard.set(NSStringFromSize(w.frame.size), forKey: WindowSizeKeeper.key)
            }
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }

    @MainActor static func apply(to window: NSWindow) {
        let saved = UserDefaults.standard.string(forKey: key).map(NSSizeFromString)
        var size = saved.flatMap { $0.width >= 400 && $0.height >= 300 ? $0 : nil } ?? NSSize(width: 980, height: 660)
        guard let screen = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        size.width = min(size.width, screen.width)
        size.height = min(size.height, screen.height)
        guard abs(window.frame.width - size.width) > 1 || abs(window.frame.height - size.height) > 1 else { return }
        // 左上角不动，放不下时挪回屏幕里
        var frame = NSRect(x: window.frame.minX, y: window.frame.maxY - size.height, width: size.width, height: size.height)
        frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
        window.setFrame(frame, display: true)
    }
}

/// 双页中间分隔线上能拖的一条：鼠标移上去变成左右箭头，拖动报告鼠标在窗口里的横坐标，双击恢复一半一半
struct SplitHandle: NSViewRepresentable {
    var onDrag: (Double) -> Void
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> HandleView { HandleView() }
    func updateNSView(_ view: HandleView, context: Context) {
        view.onDrag = onDrag
        view.onDoubleClick = onDoubleClick
    }

    final class HandleView: NSView {
        var onDrag: ((Double) -> Void)?
        var onDoubleClick: (() -> Void)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
        }
        required init?(coder: NSCoder) { fatalError() }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
        override func hitTest(_ point: NSPoint) -> NSView? {
            frame.contains(point) ? self : nil
        }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onDoubleClick?() }
        }
        override func mouseDragged(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
            onDrag?(event.locationInWindow.x)
        }
    }
}

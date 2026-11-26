import AppKit
import SwiftUI

/// 单页的编辑区（SwiftUI 包装）。文档内容始终以 Markdown 保存在 text 中。
/// 单页时铺满窗口；双页时在右边，和左边的原文实时同步。
struct RichTextEditor: NSViewRepresentable {
    @Binding var text: String
    let baseURL: URL?
    let controller: EditorController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // 使用 TextKit 1（NSLayoutManager），以便支持表格并自行绘制列表符号。
        // 不用非连续排版：表格和图片的高度估不准，打开时会停在文档中间、滚动位置乱跳
        let storage = NSTextStorage()
        let layout = RichLayoutManager()
        layout.allowsNonContiguousLayout = false
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let tv = RichTextView(frame: .zero, textContainer: container)
        tv.wantsLayer = true
        tv.layerContentsRedrawPolicy = .onSetNeedsDisplay
        tv.isRichText = true
        tv.importsGraphics = false        // 粘贴的图片无法保存到 Markdown，请用“插入图片”
        tv.usesFontPanel = false          // Markdown 不能保存字体与字号
        tv.usesRuler = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.drawsBackground = true
        tv.backgroundColor = RichStyle.paperColor
        tv.textContainerInset = NSSize(width: 32, height: 40)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        tv.typingAttributes = RichStyle.typingAttributes(for: .body)
        if #available(macOS 15.2, *) {
            tv.writingToolsBehavior = .complete
            tv.allowedWritingToolsResultOptions = [.plainText, .richText, .list, .table]
        }
        tv.baseURL = baseURL
        tv.delegate = context.coordinator

        let scroll = SplitScrollView()
        scroll.wantsLayer = true
        scroll.contentView.wantsLayer = true
        scroll.overlayScrollers = !controller.isRichMode
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = RichStyle.paperColor
        scroll.documentView = tv

        controller.richView = tv
        controller.flushRichEdits = { [weak coordinator = context.coordinator] in coordinator?.flush() }
        controller.reloadRichIfPending = { [weak coordinator = context.coordinator, weak tv] in
            guard let coordinator, let tv else { return }
            MainActor.assumeIsolated { coordinator.reloadIfPending(tv) }
        }
        tv.onAction = { [weak controller] action in controller?.perform(action) }
        tv.onOpenLink = { [weak coordinator = context.coordinator] link in coordinator?.openLink(link) }
        tv.onFocus = { [weak coordinator = context.coordinator, weak tv] in
            guard let coordinator, let tv else { return }
            MainActor.assumeIsolated { coordinator.reloadIfPending(tv) }
        }
        tv.onFocusChange = { [weak controller] focused in
            MainActor.assumeIsolated { controller?.updateSelectionState(richFocused: focused) }
        }
        // 双页：滚动右边时，左边的原文跟着滚（单页关闭通知以减少 120Hz 滚动派发开销）
        scroll.contentView.postsBoundsChangedNotifications = !controller.isRichMode
        context.coordinator.scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak controller] _ in
            MainActor.assumeIsolated { controller?.richScrolled() }
        }
        // 网络图片下载完成或“显示网络图片”开关改变：重新排版（连续多张只排一次）
        context.coordinator.remoteImageObserver = NotificationCenter.default.addObserver(
            forName: RemoteImages.changed, object: nil, queue: .main) { [weak coordinator = context.coordinator, weak tv] _ in
            MainActor.assumeIsolated {
                guard let coordinator, let tv else { return }
                coordinator.scheduleReload(tv, force: true)
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? RichTextView else { return }
        controller.richView = tv
        let baseChanged = tv.baseURL != baseURL
        // 首次显示，或文档被外部修改（“恢复到上一版本”、在双页左边的原文里编辑）时重新载入
        if text != context.coordinator.lastMarkdown || baseChanged {
            // 双页里正在左边打字：停顿一下再载入，连续输入不卡
            if context.coordinator.lastMarkdown != nil, !baseChanged, tv.window?.firstResponder !== tv {
                context.coordinator.scheduleReload(tv)
            } else {
                context.coordinator.reload(tv)
            }
        }
        // 刚切换到单页（或刚打开窗口）时把光标放到编辑区
        if !context.coordinator.wasActive {
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
        context.coordinator.wasActive = true
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let o = coordinator.scrollObserver { NotificationCenter.default.removeObserver(o) }
        if let o = coordinator.remoteImageObserver { NotificationCenter.default.removeObserver(o) }
        // 关闭窗口前，把尚未写回的修改写回文档
        DispatchQueue.main.async { coordinator.flush() }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        /// 编辑区当前内容对应的 Markdown
        var lastMarkdown: String?
        var wasActive = false
        private weak var pendingView: NSTextView?
        private weak var document: NSDocument?
        private var work: DispatchWorkItem?
        private var lastFlushSeconds = 0.0

        init(_ parent: RichTextEditor) { self.parent = parent }

        private var reloadWork: DispatchWorkItem?
        private var forceReload = false
        var scrollObserver: NSObjectProtocol?
        var remoteImageObserver: NSObjectProtocol?
        private var textBeforeWritingTools: String?

        /// force：文字没变也重新排版（网络图片下载完成）
        func scheduleReload(_ tv: RichTextView, force: Bool = false) {
            reloadWork?.cancel()
            forceReload = forceReload || force
            let item = DispatchWorkItem { [weak self, weak tv] in
                guard let self, let tv else { return }
                MainActor.assumeIsolated { self.reload(tv) }
            }
            reloadWork = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
        }

        /// 左边改了字、右边还在等着重排：马上排好
        @MainActor func reloadIfPending(_ tv: RichTextView) {
            if reloadWork != nil || tv.baseURL != parent.baseURL { reload(tv) }
        }

        /// 直接编辑源码中的 YAML；撤销和重做也只替换该片段，不回退后来修改的正文。
        @discardableResult
        @MainActor func replaceYAMLFrontMatter(_ previous: String, with replacement: String, in tv: RichTextView) -> Bool {
            guard pendingView == nil, !tv.hasMarkedText(),
                  let updated = MarkdownCodec.replacingYAMLFrontMatterPrefix(previous, with: replacement, in: parent.text) else { return false }
            guard !previous.utf8.elementsEqual(replacement.utf8) else { return true }
            tv.undoManager?.registerUndo(withTarget: self) { [weak tv] coordinator in
                guard let tv else { return }
                MainActor.assumeIsolated {
                    coordinator.flush()
                    coordinator.replaceYAMLFrontMatter(replacement, with: previous, in: tv)
                }
            }
            parent.text = updated
            reload(tv, preservesUndo: true)
            return true
        }

        /// 按文档的 Markdown 重新排单页；光标和滚动位置尽量不变（双页里左边改了字，右边不跳回顶部）
        @MainActor func reload(_ tv: RichTextView, preservesUndo: Bool = false) {
            reloadWork?.cancel()
            reloadWork = nil
            // 目录改变时等单页修改写回；这时绑定尚没有刚打的字。
            guard pendingView == nil, !tv.hasMarkedText(), let storage = tv.textStorage else { return }
            let text = parent.text
            let textChanged = text != lastMarkdown
            let force = forceReload
            forceReload = false
            guard textChanged || force || tv.baseURL != parent.baseURL || storage.length == 0 else { return }
            lastMarkdown = text
            tv.baseURL = parent.baseURL
            let clip = tv.enclosingScrollView?.contentView
            let origin = clip?.bounds.origin
            let selection = tv.selectedRange()
            let (content, map) = RichBridge.attributedWithLineMap(markdown: text, baseURL: parent.baseURL)
            // 路径变更也可能把图片占位文字变成单字符附件，旧撤销操作的偏移此时已失效。
            if !preservesUndo, textChanged || storage.string != content.string {
                tv.undoManager?.removeAllActions(withTarget: storage)
            }
            storage.setAttributedString(content)
            let length = storage.length
            let caret = min(selection.location, length)
            tv.setSelectedRange(NSRange(location: caret, length: textChanged ? 0 : min(selection.length, length - caret)))
            tv.typingAttributes = length > 0
                ? storage.attributes(at: min(tv.selectedRange().location, length - 1), effectiveRange: nil)
                : RichStyle.typingAttributes(for: .body)
            if let clip, let origin {
                clip.scroll(to: origin)
                tv.enclosingScrollView?.reflectScrolledClipView(clip)
            }
            parent.controller.selectionChanged()
            parent.controller.richReloaded(lineMap: map, for: text)
        }

        /// 右边要改字了：先告诉双页“对照表要过期”。系统打字时先发“选区变”再发 textDidChange，
        /// 用输入法打拼音时根本没有 textDidChange；等到那时才标，左边的标记会按旧对照表跳到下一段
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            MainActor.assumeIsolated { parent.controller.richTextEdited = true }
            return true
        }

        func textDidChange(_ notification: Notification) {
            pendingView = notification.object as? NSTextView
            // 登记为文档的编辑器：保存、关窗、退出前系统会先让它交出修改（见下面的 NSEditor）
            if document == nil, let window = pendingView?.window,
               let doc = NSDocumentController.shared.document(for: window) {
                document = doc
                doc.objectDidBeginEditing(self)
            }
            // 停顿片刻再转换为 Markdown，连续输入时不卡顿（自动保存会在之后写入）
            work?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.flush() }
            work = item
            // 文档越大转换越久：等待时间跟着上次的耗时变长，长文档里不会每次停顿都卡一下（保存、关窗前仍立刻写回）
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.25, min(3, lastFlushSeconds * 8)), execute: item)
        }

        func textDidEndEditing(_ notification: Notification) {
            flush()
            MainActor.assumeIsolated {
                if let tv = notification.object as? RichTextView, tv.baseURL != parent.baseURL { reload(tv) }
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            MainActor.assumeIsolated {
                parent.controller.selectionChanged()
                parent.controller.syncSourceMark()
            }
        }

        @available(macOS 15.0, *)
        func textViewWritingToolsWillBegin(_ textView: NSTextView) {
            textBeforeWritingTools = parent.text
            work?.cancel()
            reloadWork?.cancel()
        }

        @available(macOS 15.0, *)
        func textViewWritingToolsDidEnd(_ textView: NSTextView) {
            flush()
            let changed = textBeforeWritingTools != parent.text
            textBeforeWritingTools = nil
            guard changed else { return }
            MainActor.assumeIsolated {
                parent.controller.selectionChanged()
            }
        }

        @available(macOS 15.0, *)
        func textView(_ textView: NSTextView, writingToolsIgnoredRangesInEnclosingRange enclosingRange: NSRange) -> [NSValue] {
            guard let storage = textView.textStorage else { return [] }
            return WritingToolsGuard.ignoredRanges(in: storage, enclosingRange: enclosingRange)
        }

        /// 把编辑区内容转换为 Markdown 写回文档
        func flush() {
            work?.cancel()
            work = nil
            document?.objectDidEndEditing(self)
            document = nil
            guard let tv = pendingView, let storage = tv.textStorage else { return }
            pendingView = nil
            // 没改过的段落保持原文，只有改过的才按标准写法写
            let started = Date()
            let md = MarkdownCodec.serialize(RichBridge.blocks(from: storage), preserving: parent.text)
            lastFlushSeconds = Date().timeIntervalSince(started)
            lastMarkdown = md
            if parent.text != md { parent.text = md }
            MainActor.assumeIsolated {
                parent.controller.richTextEdited = false
                parent.controller.richMarkdown = md
                if let tv = tv as? RichTextView, tv.baseURL != parent.baseURL { reload(tv) }
                parent.controller.syncSourceMark()
            }
        }

        /// 单击链接：按设置直接打开、先确认，或按住 ⌘ 才打开（按住 ⌘ 总是直接打开）
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let command = NSEvent.modifierFlags.contains(.command)
            switch LinkClickAction.current {
            case .open: openLink(link)
            case .command: if command { openLink(link) }
            case .confirm:
                if command { openLink(link); break }
                let target = LinkTarget.resolve(link, baseURL: parent.baseURL)
                // 打不开的不用先问，直接说为什么打不开；文内跳转不处理
                switch target {
                case .web, .markdown, .file: break
                default: openLink(link); return true
                }
                guard let window = textView.window else { break }
                let alert = NSAlert()
                alert.messageText = String(localized: "要打开这个链接吗？")
                alert.informativeText = target.display
                alert.addButton(withTitle: String(localized: "打开"))
                alert.addButton(withTitle: String(localized: "取消"))
                alert.beginSheetModal(for: window) { [weak self] response in
                    if response == .alertFirstButtonReturn { self?.openLink(link) }
                }
            }
            return true
        }

        /// 打开链接：网页用浏览器；本机的 Markdown 文件用 DropMD 打开，其他文件在访达中显示；
        /// 文件找不到、链接打不开时弹出提示
        func openLink(_ link: Any) {
            switch LinkTarget.resolve(link, baseURL: parent.baseURL) {
            case .web(let url):
                if !NSWorkspace.shared.open(url) {
                    showLinkError(String(localized: "无法打开这个链接"), detail: url.absoluteString)
                }
            case .markdown(let url):
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { [weak self] _, _, error in
                    if let error { self?.showLinkError(String(localized: "无法打开这个文件"), detail: error.localizedDescription) }
                }
            case .file(let url):
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case .missing(let path):
                showLinkError(String(localized: "找不到链接指向的文件"),
                              detail: parent.baseURL == nil && !path.hasPrefix("/")
                                ? String(localized: "文档还没有保存，无法按相对路径查找：\(path)")
                                : String(localized: "文件可能已被移动、改名或删除：\(path)"))
            case .unsupported(let text):
                showLinkError(String(localized: "不支持打开这种链接"), detail: text)
            case .anchor:
                break
            }
        }

        private func showLinkError(_ title: String, detail: String) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = detail
            alert.addButton(withTitle: String(localized: "好"))
            if let window = NSApp.keyWindow { alert.beginSheetModal(for: window) } else { alert.runModal() }
        }
    }
}

// MARK: - 保存、关闭文档前写回单页的修改
// 单页的修改停顿片刻才写回文档；刚打完字就按 ⌘S、⌘W 或退出时，系统先调用这里，最后几个字不会丢

extension RichTextEditor.Coordinator: NSEditor {
    func commitEditing() -> Bool {
        flush()
        return true
    }

    func commitEditingWithoutPresentingError() throws {
        flush()
    }

    func discardEditing() {}

    func commitEditing(withDelegate delegate: Any?, didCommit didCommitSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        flush()
        guard let target = delegate as? NSObject, let sel = didCommitSelector, let imp = target.method(for: sel) else { return }
        // 回调的形式：- (void)editor:(id)editor didCommit:(BOOL)didCommit contextInfo:(void *)contextInfo
        typealias Callback = @convention(c) (AnyObject, Selector, AnyObject, Bool, UnsafeMutableRawPointer?) -> Void
        unsafeBitCast(imp, to: Callback.self)(target, sel, self, true, contextInfo)
    }
}

import AppKit
import SwiftUI

/// 单页的编辑区（SwiftUI 包装）。文档内容始终以 Markdown 保存在 text 中。
/// 切换到双页时不销毁（isActive 为 false 时隐藏且不做任何同步），切换回来不卡顿。
struct RichTextEditor: NSViewRepresentable {
    @Binding var text: String
    let baseURL: URL?
    let controller: EditorController
    var isActive = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // 使用 TextKit 1（NSLayoutManager），以便支持表格并自行绘制列表符号
        let storage = NSTextStorage()
        let layout = RichLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let tv = RichTextView(frame: .zero, textContainer: container)
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
        tv.baseURL = baseURL
        tv.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = RichStyle.paperColor
        scroll.documentView = tv

        controller.richView = tv
        controller.flushRichEdits = { [weak coordinator = context.coordinator] in coordinator?.flush() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        scroll.isHidden = !isActive
        if !isActive { context.coordinator.wasActive = false }
        guard isActive, let tv = scroll.documentView as? RichTextView, let storage = tv.textStorage else { return }
        controller.richView = tv
        let baseChanged = tv.baseURL != baseURL
        tv.baseURL = baseURL
        // 首次显示，或文档被外部修改（“恢复到上一版本”、在双页中编辑）时重新载入
        if text != context.coordinator.lastMarkdown || baseChanged {
            context.coordinator.lastMarkdown = text
            let selection = tv.selectedRange()
            storage.setAttributedString(RichBridge.attributed(markdown: text, baseURL: baseURL))
            let length = storage.length
            tv.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            tv.typingAttributes = length > 0
                ? storage.attributes(at: min(tv.selectedRange().location, length - 1), effectiveRange: nil)
                : RichStyle.typingAttributes(for: .body)
            tv.undoManager?.removeAllActions(withTarget: storage)
            controller.selectionChanged()
        }
        // 刚切换到单页（或刚打开窗口）时把光标放到编辑区
        if !context.coordinator.wasActive {
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
        context.coordinator.wasActive = true
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        // 关闭窗口前，把尚未写回的修改写回文档
        DispatchQueue.main.async { coordinator.flush() }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        /// 编辑区当前内容对应的 Markdown
        var lastMarkdown: String?
        var wasActive = false
        private weak var pendingView: NSTextView?
        private var work: DispatchWorkItem?

        init(_ parent: RichTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            pendingView = notification.object as? NSTextView
            // 停顿片刻再转换为 Markdown，连续输入时不卡顿（自动保存会在之后写入）
            work?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.flush() }
            work = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
        }

        func textDidEndEditing(_ notification: Notification) {
            flush()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            MainActor.assumeIsolated { parent.controller.selectionChanged() }
        }

        /// 把编辑区内容转换为 Markdown 写回文档
        func flush() {
            work?.cancel()
            work = nil
            guard let tv = pendingView, let storage = tv.textStorage else { return }
            pendingView = nil
            let md = RichBridge.markdown(from: storage)
            lastMarkdown = md
            if parent.text != md { parent.text = md }
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            // 按住 ⌘ 点击链接才打开，普通点击用于编辑文字
            guard NSEvent.modifierFlags.contains(.command) else { return true }
            var url = link as? URL
            if url == nil, let s = link as? String { url = URL(string: s) }
            guard let url else { return true }
            if url.scheme == nil || url.isFileURL {
                let target = url.isFileURL ? url : URL(fileURLWithPath: url.path, relativeTo: parent.baseURL)
                if ["md", "markdown", "mdown"].contains(target.pathExtension.lowercased()) {
                    NSDocumentController.shared.openDocument(withContentsOf: target, display: true) { _, _, _ in }
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([target])
                }
            } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            return true
        }
    }
}

import AppKit
import SwiftUI

/// 独立文章摘要窗口的数据状态
@MainActor
final class SummaryPanelModel: ObservableObject {
    @Published var documentTitle = ""
    @Published var isLoading = false
    @Published var bullets: [String] = []
    @Published var errorMessage: String?
    @Published var copied = false
}

/// 独立文章摘要窗口界面（非模态，支持复制、重新生成、一键插入文档）
struct ArticleSummaryView: View {
    @ObservedObject var model: SummaryPanelModel
    var onRegenerate: () -> Void
    var onInsert: ([String]) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footerBar
        }
        .frame(minWidth: 360, minHeight: 260)
    }

    @ViewBuilder
    private var contentArea: some View {
        if model.isLoading {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                Text("正在生成文章摘要…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        } else if let error = model.errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("重试", action: onRegenerate)
            }
            .padding(24)
        } else if model.bullets.isEmpty {
            Text("暂无摘要内容")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(24)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(model.bullets.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 8) {
                            Text(verbatim: "•")
                                .foregroundStyle(.secondary)
                            Text(verbatim: item)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(18)
            }
        }
    }

    private var footerBar: some View {
        HStack(spacing: 10) {
            Button(model.copied ? String(localized: "已复制") : String(localized: "复制")) {
                let text = model.bullets.map { "- \($0)" }.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                model.copied = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    model.copied = false
                }
            }
            .disabled(model.isLoading || model.bullets.isEmpty)

            Button("插入到文档") {
                onInsert(model.bullets)
            }
            .disabled(model.isLoading || model.bullets.isEmpty)

            Spacer()

            Button("重新生成", action: onRegenerate)
                .disabled(model.isLoading)

            Button("关闭", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// 持有并展示非模态文章摘要窗口
@MainActor
final class ArticleSummaryWindowController: NSObject, NSWindowDelegate {
    let model = SummaryPanelModel()
    private var window: NSWindow?
    private var onRegenerate: (() -> Void)?
    private var onInsert: (([String]) -> Void)?
    private var onWindowClose: (() -> Void)?

    func show(
        title: String,
        relativeTo parentWindow: NSWindow?,
        onRegenerate: @escaping () -> Void,
        onInsert: @escaping ([String]) -> Void,
        onWindowClose: @escaping () -> Void
    ) {
        self.onRegenerate = onRegenerate
        self.onInsert = onInsert
        self.onWindowClose = onWindowClose
        model.documentTitle = title

        let w: NSWindow
        if let existing = window {
            w = existing
        } else {
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            created.isReleasedWhenClosed = false
            created.delegate = self
            let view = ArticleSummaryView(
                model: model,
                onRegenerate: { [weak self] in self?.onRegenerate?() },
                onInsert: { [weak self] bullets in self?.onInsert?(bullets) },
                onClose: { [weak self] in self?.close() }
            )
            created.contentViewController = NSHostingController(rootView: view)
            if let parentWindow {
                let p = parentWindow.frame
                let origin = NSPoint(
                    x: p.midX - created.frame.width / 2,
                    y: p.midY - created.frame.height / 2
                )
                created.setFrameOrigin(origin)
            } else {
                created.center()
            }
            window = created
            w = created
        }

        let baseTitle = String(localized: "文章摘要")
        w.title = title.isEmpty ? baseTitle : "\(baseTitle) — \(title)"
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        onWindowClose?()
    }
}

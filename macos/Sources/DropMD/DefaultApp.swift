import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 把 DropMD 设为 Markdown 文件的默认打开程序（在访达中双击 .md 时用哪个 App 打开）
@MainActor
enum DefaultApp {
    /// 系统给 .md 认定的类型（别的编辑器可能声明了自己的类型，按扩展名取才准）
    private static var markdown: UTType {
        UTType(filenameExtension: "md") ?? UTType("net.daringfireball.markdown")!
    }

    static var isDefault: Bool {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: markdown) else { return false }
        return Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// 设为默认；系统可能先弹窗请用户确认。失败时提示原因
    static func makeDefault() async {
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: markdown)
        } catch {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = String(localized: "无法设为默认")
            a.informativeText = error.localizedDescription
            a.addButton(withTitle: String(localized: "好"))
            a.runModal()
        }
    }

    /// 第一次启动时问一次；已经是默认时不问
    static func askOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "askedDefaultApp") else { return }
        defaults.set(true, forKey: "askedDefaultApp")
        guard !isDefault else { return }
        let a = NSAlert()
        a.messageText = String(localized: "用 DropMD 打开 Markdown 文件？")
        a.informativeText = String(localized: "设为默认后，在访达中双击 .md 文件会用 DropMD 打开。以后可以在“设置”中更改。")
        a.addButton(withTitle: String(localized: "设为默认"))
        a.addButton(withTitle: String(localized: "暂不"))
        if a.runModal() == .alertFirstButtonReturn {
            Task { await makeDefault() }
        }
    }
}

/// “DropMD → 设置…”
struct SettingsView: View {
    @State private var isDefault = DefaultApp.isDefault
    @State private var working = false

    var body: some View {
        Form {
            LabeledContent("Markdown 文件") {
                if isDefault {
                    Label("DropMD 是默认打开程序", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Button("将 DropMD 设为默认") {
                        working = true
                        Task {
                            await DefaultApp.makeDefault()
                            isDefault = DefaultApp.isDefault
                            working = false
                        }
                    }
                    .disabled(working)
                }
            }
            Text("在访达中双击 .md 文件时，用默认打开程序打开。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
        // 用户可能在访达的“显示简介”里改了默认程序，回到 DropMD 时重新查看
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isDefault = DefaultApp.isDefault
        }
    }
}

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

/// 界面语言：写入本 App 的 AppleLanguages（与“系统设置 → 语言与地区 → App”相同），重新启动后生效
enum AppLanguage {
    /// 语言名用各自的文字写，不翻译（与系统设置相同）
    static let choices = [("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("en", "English"), ("ja", "日本語")]

    /// 空字符串表示跟随系统
    static var current: String {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        // 系统设置里选的可能带地区（ja-JP、zh-Hant-TW），归到这四种
        guard let code = (domain?["AppleLanguages"] as? [String])?.first else { return "" }
        return code.hasPrefix("zh-Hant") || code.hasPrefix("zh-TW") || code.hasPrefix("zh-HK") ? "zh-Hant"
            : code.hasPrefix("zh") ? "zh-Hans" : code.hasPrefix("ja") ? "ja" : code.hasPrefix("en") ? "en" : ""
    }

    @MainActor static func set(_ code: String) {
        guard code != current else { return }
        if code.isEmpty {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        }
        let a = NSAlert()
        a.messageText = String(localized: "重新启动 DropMD 后，界面语言才会改变。")
        a.addButton(withTitle: String(localized: "立即重新启动"))
        a.addButton(withTitle: String(localized: "稍后"))
        if a.runModal() == .alertFirstButtonReturn { relaunch() }
    }

    /// 退出后重新打开；有未保存的文档时系统会先问，取消退出就不重新打开
    @MainActor private static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", #"n=0; while kill -0 "$1" 2>/dev/null && [ $n -lt 300 ]; do sleep 0.2; n=$((n+1)); done; "#
                       + #"kill -0 "$1" 2>/dev/null || open "$2""#,
                       "sh", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// “DropMD → 设置…”
struct SettingsView: View {
    @State private var isDefault = DefaultApp.isDefault
    @State private var working = false
    @State private var language = AppLanguage.current

    var body: some View {
        Form {
            Picker("界面语言", selection: $language) {
                Text("跟随系统").tag("")
                Divider()
                ForEach(AppLanguage.choices, id: \.0) { Text(verbatim: $0.1).tag($0.0) }
            }
            .onChange(of: language) { _, newValue in AppLanguage.set(newValue) }

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

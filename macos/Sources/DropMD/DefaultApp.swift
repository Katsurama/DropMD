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

/// “DropMD → 设置…”：和苹果自带 App 一样分成几页（顶部的标签），不再是一长条
struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"   // 苹果的设计规范：再打开时回到上次看的那一页

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag("general")
            UpdateSettings()
                .tabItem { Label("更新", systemImage: "arrow.triangle.2.circlepath") }
                .tag("updates")
            AboutSettings()
                .tabItem { Label("关于", systemImage: "info.circle") }
                .tag("about")
        }
        .frame(width: 460)
        .fixedSize()
    }
}

/// 通用：外观、页边距、界面语言、默认打开程序
private struct GeneralSettings: View {
    @State private var isDefault = DefaultApp.isDefault
    @State private var working = false
    @State private var language = AppLanguage.current

    var body: some View {
        Form {
            Section("显示") {
                AppearanceMenu()
                PageMarginMenu()
                Text("页边距只影响单页。选“自动”时，窗口越大，文字那一栏越宽。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("语言") {
                Picker("界面语言", selection: $language) {
                    Text("跟随系统").tag("")
                    Divider()
                    ForEach(AppLanguage.choices, id: \.0) { Text(verbatim: $0.1).tag($0.0) }
                }
                .onChange(of: language) { _, newValue in AppLanguage.set(newValue) }
            }
            Section("Markdown 文件") {
                LabeledContent("默认打开程序") {
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
        }
        .formStyle(.grouped)
        .scrollDisabled(true)   // 内容放得下，不显示滚动条
        .fixedSize(horizontal: false, vertical: true)
        // 用户可能在访达的“显示简介”里改了默认程序，回到 DropMD 时重新查看
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isDefault = DefaultApp.isDefault
        }
    }
}

/// 更新：当前版本、检查更新（自动检查、测试版的开关只在更新窗口里，免得两处看着像冲突）
private struct UpdateSettings: View {
    @ObservedObject private var updater = UpdateChecker.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                LabeledContent("当前版本") {
                    HStack {
                        Text(verbatim: UpdateChecker.currentVersionText)
                            .foregroundStyle(.secondary)
                        Button("检查更新…") {
                            openWindow(id: "updates")
                            Task { await updater.check() }
                        }
                        .disabled(UpdateChecker.repository == nil || updater.state == .checking)
                    }
                }
                Text("“启动时自动检查更新”和“包括测试版”在“检查更新…”打开的窗口里设置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)   // 内容放得下，不显示滚动条
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 关于：图标和版本、仓库 / 反馈 / Discord，最下面是赞助卡片
private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                Text(verbatim: "DropMD")
                    .font(.title2.weight(.semibold))
                Text("版本 \(UpdateChecker.currentVersionText)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)

            Form {
                Section {
                    if let repo = UpdateChecker.repository, let url = HelpDocs.repoURL() {
                        LabeledContent("GitHub 仓库") {
                            Link(destination: url) { Text(verbatim: "github.com/\(repo)") }
                        }
                    }
                    if let issues = HelpDocs.repoURL(path: "/issues") {
                        LabeledContent("遇到问题") {
                            Link("反馈问题…", destination: issues)
                        }
                    }
                    LabeledContent("交流") {
                        Link(destination: HelpDocs.discord) { Text(verbatim: "Discord") }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, -20)   // 和下面的卡片左右对齐（分组表单自带左右留白）
            .padding(.vertical, -12)

            SponsorCard()
        }
        .padding(20)
    }
}

/// 赞助按钮的样子：粉色实心胶囊
private struct SponsorLabel: View {
    let name: String
    var body: some View {
        Text(verbatim: name)
            .font(.callout.weight(.semibold))
            .frame(minWidth: 80)
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .foregroundStyle(.white)
            .background(Color.pink.gradient, in: Capsule())
    }
}

/// 赞助卡片：粉色的心、一句话、实心按钮
private struct SponsorCard: View {
    @State private var showWeChat = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "heart.fill")
                .font(.system(size: 26))
                .foregroundStyle(.pink)
            Text("喜欢 DropMD？")
                .font(.headline)
            Text("如果它帮到了你，可以请我喝杯咖啡，支持我继续更新")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                ForEach(HelpDocs.sponsors, id: \.url) { s in
                    Link(destination: s.url) { SponsorLabel(name: s.name) }
                        .buttonStyle(.plain)
                }
                // 微信赞赏码：只在中文界面显示（随 App 带的图片，不联网）
                if let qr = HelpDocs.wechatQR {
                    Button { showWeChat.toggle() } label: { SponsorLabel(name: String(localized: "微信")) }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showWeChat, arrowEdge: .bottom) {
                            VStack(spacing: 8) {
                                Image(nsImage: qr)
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: 220, height: 220)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                Text("用微信扫一扫")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(16)
                        }
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(Color.pink.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.pink.opacity(0.18)))
    }
}

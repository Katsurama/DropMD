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

/// “DropMD → 设置…”：按当前标签页自适应高度，各页自然贴合
struct SettingsView: View {
    @AppStorage("settingsTab") private var page = SettingsPage.general   // 苹果的设计规范：再打开时回到上次看的那一页

    var body: some View {
        TabView(selection: $page) {
            GeneralSettings()
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(SettingsPage.general)
            UpdateView(updater: UpdateChecker.shared)
                .frame(height: 460)
                .tabItem { Label("更新", systemImage: "arrow.triangle.2.circlepath") }
                .tag(SettingsPage.updates)
            SponsorSettings()
                .tabItem { Label("赞助", systemImage: "heart") }
                .tag(SettingsPage.sponsor)
            AboutSettings()
                .tabItem { Label("关于", systemImage: "info.circle") }
                .tag(SettingsPage.about)
        }
        .frame(width: 500)
    }
}

/// 设置窗口的各页；菜单“关于 DropMD”“检查更新…”直接打开对应的页
enum SettingsPage: String {
    case general, updates, sponsor, about

    @MainActor static func open(_ page: SettingsPage, _ openSettings: OpenSettingsAction) {
        UserDefaults.standard.set(page.rawValue, forKey: "settingsTab")
        openSettings()
    }
}

/// 通用：外观、页边距与双页标记、链接、语言、默认打开程序
private struct GeneralSettings: View {
    @State private var isDefault = DefaultApp.isDefault
    @State private var working = false
    @State private var language = AppLanguage.current

    var body: some View {
        Form {
            Section("显示") {
                AppearanceMenu()
                PageMarginMenu(note: "不影响导出与保存。")
                TextScaleMenu(note: "选择“自动”时，按屏幕分辨率调整。不影响导出与保存。")
                SourceMarkMenu(note: "在双页中，于另一侧标示光标的对应位置。", styleNote: "仅用于右侧预览。左侧原文以整行底色标示。")
                RemoteImagesToggle()
            }
            Section("链接") {
                LinkClickPicker()
            }
            Section("语言") {
                Picker("界面语言", selection: $language) {
                    Text("跟随系统").tag("")
                    Divider()
                    ForEach(AppLanguage.choices, id: \.0) { Text(verbatim: $0.1).tag($0.0) }
                }
                .onChange(of: language) { _, newValue in AppLanguage.set(newValue) }
            }
            if SiriAIManager.isPrivateCloudAvailable {
                Section {
                    AIModelPicker()
                } header: {
                    Text(verbatim: "Apple Intelligence")
                }
            }
            Section("Markdown 文件") {
                LabeledContent {
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
                } label: {
                    Text("默认打开程序")
                    Text("在访达中双击 .md 文件时使用的应用。")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 420, idealHeight: 460)
        // 用户可能在访达的“显示简介”里改了默认程序，回到 DropMD 时重新查看
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isDefault = DefaultApp.isDefault
        }
    }
}

/// 设置 → 通用：Apple 私有云计算与本机模型调度策略（仅 macOS 27+ 显示）
private struct AIModelPicker: View {
    @AppStorage(AIModelPreference.storageKey) private var preference = AIModelPreference.defaultValue

    var body: some View {
        Picker(selection: $preference) {
            ForEach(AIModelPreference.allCases) { Text($0.title).tag($0) }
        } label: {
            Text("智能模型")
            Text("默认为“自动”：处理长文档时，相关内容可能发送给 Apple 私有云计算；云端不可用时改用本机模型。选择“仅本机”则全部在这台 Mac 上处理。")
        }
    }
}

/// 关于：图标和版本、仓库 / 反馈 / Discord、开源许可、版权（取代系统的“关于”窗口）
private struct AboutSettings: View {
    @State private var license: LicenseText?
    private var build: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "" }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                Text(verbatim: "DropMD")
                    .font(.title2.weight(.semibold))
                Text("版本 \(UpdateChecker.currentVersionText) (\(build))")
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
                        HStack(spacing: 12) {
                            if HelpDocs.showsQQGroup {
                                Link(destination: HelpDocs.qqGroup) { Text(verbatim: "QQ 群") }
                            }
                            Link(destination: HelpDocs.discord) { Text(verbatim: "Discord") }
                        }
                    }
                }
                Section {
                    LabeledContent("开源许可") {
                        HStack {
                            Button("DropMD 许可证") { license = .app }
                            Button("第三方组件") { license = .thirdParty }
                        }
                    }
                    Text("使用了 markdown-it、KaTeX、MarkItDown、Docling、Pandoc 等开源组件，中文字体为小米 MiSans。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, -20)   // 分组表单自带左右留白，和上下内容对齐
            .padding(.vertical, -12)

            Text(verbatim: "Copyright © 2026 DropMD contributors. MIT License.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        // 许可证全文直接在设置里看（不再复制成 .md 文件打开）
        .sheet(item: $license) { item in
            VStack(alignment: .leading, spacing: 12) {
                Text(item.title).font(.headline)
                ScrollView {
                    Text(item.content)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Spacer()
                    Button("完成") { license = nil }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 460, height: 440)
        }
    }
}

/// 设置 → 关于里显示的许可证全文（随 App 带的文件）
private enum LicenseText: String, Identifiable {
    case app, thirdParty
    var id: String { rawValue }
    var title: String { self == .app ? String(localized: "DropMD 许可证") : String(localized: "第三方组件") }
    var content: AttributedString {
        let name = self == .app ? "LICENSE" : "THIRD_PARTY_LICENSES.md"
        let text = Bundle.main.url(forResource: name, withExtension: nil)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map(Self.plain) ?? String(localized: "找不到许可证文件。")
        // 第三方清单是 Markdown：链接可以点，粗体等照样显示
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    /// 只认行内写法，# 标题、- 列表、| 表格 | 会原样显示：大标题去掉（面板上方已有标题），小标题改粗体，列表和表格每行改成“• ”开头的一条
    static func plain(_ md: String) -> String {
        var header = true
        return md.components(separatedBy: "\n").compactMap { line -> String? in
            if line.hasPrefix("# ") { return nil }
            if line.hasPrefix("## ") { header = true; return "**\(line.dropFirst(3))**" }
            if line.hasPrefix("- ") { return "• " + line.dropFirst(2) }
            guard line.hasPrefix("|") else { return line }
            if header || line.hasPrefix("|-") || line.hasPrefix("|:") { header = false; return nil }   // 表头、分隔行
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return "• " + cells.joined(separator: " — ")
        }.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }
}

/// 赞助：单独一页，粉色卡片
private struct SponsorSettings: View {
    var body: some View {
        SponsorCard()
            .padding(20)
    }
}

/// 赞助按钮的样子：粉色实心胶囊
private struct SponsorLabel: View {
    let name: String
    var body: some View {
        Text(verbatim: name)
            .font(.callout.weight(.semibold))
            .frame(minWidth: 60)   // 中文界面有 4 个按钮（含微信），一行要放得下
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

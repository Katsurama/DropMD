import AppKit
import SwiftUI

@main
struct DropMDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var converter = AppModel()

    init() {
        // 随 App 提供的 MiSans 字体：只在本 App 内使用，不安装到系统
        if let dir = Bundle.main.resourceURL?.appendingPathComponent("fonts"),
           let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            CTFontManagerRegisterFontURLs(files as CFArray, .process, true, nil)
        }
    }

    var body: some Scene {
        // 主功能：Markdown 编辑器（新建、打开、自动保存、版本历史由系统文档机制提供）
        DocumentGroup(newDocument: MarkdownDocument()) { file in
            EditorView(document: file.$document, fileURL: file.fileURL)
        }
        .defaultSize(width: 980, height: 660)
        .commands {
            CommandGroup(replacing: .appInfo) {
                SettingsPageButton(title: "关于 DropMD", page: .about)
            }
            CommandGroup(after: .appInfo) {
                OpenUpdatesButton()
            }
            // 只留“隐藏 DropMD”，不要“隐藏其他”“全部显示”
            CommandGroup(replacing: .appVisibility) {
                Button("隐藏 DropMD") { NSApp.hide(nil) }
                    .keyboardShortcut("h")
            }
            CommandGroup(after: .newItem) {
                Divider()
                OpenConverterButton()
                Menu("高精度识别模型") {
                    Button("下载当前设置所需的模型…") {
                        Task { _ = await converter.ensureModels(showWhenPresent: true) }
                    }
                    .disabled(converter.running)
                    Button("打开模型文件夹") {
                        Task {
                            // 还没打开过转换窗口时没有引擎信息：先查一次
                            if converter.engineStatus == nil { await converter.loadStatus() }
                            if let dir = converter.engineStatus?.modelsDir {
                                let url = URL(fileURLWithPath: dir)
                                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
            FormatCommands()
            CommandGroup(replacing: .help) {
                Button("使用说明") { HelpDocs.openGuide() }
                Button("隐私说明") {
                    let a = NSAlert()
                    a.messageText = String(localized: "隐私说明")
                    a.informativeText = privacyText
                    a.addButton(withTitle: String(localized: "好"))
                    a.runModal()
                }
                if let url = HelpDocs.repoURL(path: "/issues") {
                    Button("反馈问题…") { NSWorkspace.shared.open(url) }
                }
                // QQ 群只在中文界面显示（简体、繁体写法相同，不用翻译）
                if HelpDocs.showsQQGroup {
                    Button { NSWorkspace.shared.open(HelpDocs.qqGroup) } label: { Text(verbatim: "加入 QQ 交流群…") }
                }
                Button("加入 Discord 社区…") { NSWorkspace.shared.open(HelpDocs.discord) }
                Divider()
                ForEach(HelpDocs.sponsors, id: \.url) { s in
                    Button(s.menuTitle) { NSWorkspace.shared.open(s.url) }
                }
                Divider()
                SettingsPageButton(title: "开源许可…", page: .about)
            }
        }

        // 文件转换（从“文件”菜单或工具栏打开）
        Window("转换为 Markdown", id: "converter") {
            ContentView()
                .environmentObject(converter)
        }
        .defaultSize(width: 1060, height: 720)

        // 设置（菜单“DropMD → 设置…”，⌘,）
        Settings {
            SettingsView()
        }
    }
}

/// 外观：跟随系统 / 浅色 / 深色（保存在偏好设置的 appearance 中）
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return String(localized: "跟随系统")
        case .light: return String(localized: "浅色")
        case .dark: return String(localized: "深色")
        }
    }

    @MainActor
    static func apply(_ value: String?) {
        switch AppAppearance(rawValue: value ?? "") ?? .system {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// 菜单“显示 → 外观”
struct AppearanceMenu: View {
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue

    var body: some View {
        Picker("外观", selection: $appearance) {
            ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
        }
        .onChange(of: appearance) { _, newValue in AppAppearance.apply(newValue) }
    }
}

/// 菜单“显示 → 页边距”（单页）
struct PageMarginMenu: View {
    @AppStorage("pageMargin") private var margin = PageMargin.auto.rawValue
    var note: LocalizedStringKey?   // 设置页里写在名称下面的说明；菜单栏不用

    var body: some View {
        Picker(selection: $margin) {
            ForEach(PageMargin.allCases) { Text($0.title).tag($0.rawValue) }
        } label: {
            Text("页边距")
            if let note { Text(note) }
        }
    }
}

/// 菜单“显示 → 字号”（单页、双页）
struct TextScaleMenu: View {
    @AppStorage("textScale") private var scale = TextScale.auto.rawValue
    var note: LocalizedStringKey?

    var body: some View {
        Picker(selection: $scale) {
            ForEach(TextScale.allCases) { Text($0.title).tag($0.rawValue) }
        } label: {
            Text("字号")
            if let note { Text(note) }
        }
    }
}

/// 设置里“点击链接时”怎么做
struct LinkClickPicker: View {
    @AppStorage("linkClickAction") private var action = LinkClickAction.confirm.rawValue

    var body: some View {
        Picker("点击链接时", selection: $action) {
            ForEach(LinkClickAction.allCases) { Text($0.title).tag($0.rawValue) }
        }
    }
}

/// 菜单“显示”和设置里的双页位置标记：上面是开关，下面是样式（关掉时样式不能选）
struct SourceMarkMenu: View {
    @AppStorage("showSourceMark") private var isOn = true
    @AppStorage("sourceMarkStyle") private var style = SourceMarkStyle.box.rawValue
    var note: LocalizedStringKey?
    var styleNote: LocalizedStringKey?

    var body: some View {
        Toggle(isOn: $isOn) {
            Text("显示对应位置标记")
            if let note { Text(note) }
        }
        Picker(selection: $style) {
            ForEach(SourceMarkStyle.allCases) { Text($0.title).tag($0.rawValue) }
        } label: {
            Text("标记样式")
            if let styleNote { Text(styleNote) }
        }
        .disabled(!isOn)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppAppearance.apply(UserDefaults.standard.string(forKey: "appearance")) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 等文档窗口出现后再询问、检查，避免与“打开文件”面板同时弹出
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                DefaultApp.askOnFirstLaunch()
                HelpDocs.openGuideOnFirstLaunch()
                UpdateChecker.shared.launchCheck()
            }
        }
    }
}

/// “DropMD → 检查更新…”：打开设置的“更新”页并马上检查；启动时发现新版本、点“查看”也打开这一页
struct OpenUpdatesButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("检查更新…") {
            SettingsPage.open(.updates, openSettings)
            Task { await UpdateChecker.shared.check() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showUpdates)) { _ in
            SettingsPage.open(.updates, openSettings)
        }
    }
}

/// 打开设置窗口的某一页（菜单“关于 DropMD”等）
struct SettingsPageButton: View {
    let title: LocalizedStringKey
    let page: SettingsPage
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(title) { SettingsPage.open(page, openSettings) }
    }
}

/// “文件 → 转换文件为 Markdown…”
struct OpenConverterButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("转换文件为 Markdown…") { openWindow(id: "converter") }
            .keyboardShortcut("t", modifiers: [.command, .shift])
    }
}

/// 作用于当前编辑器窗口的菜单：文件（导出）、显示、格式、插入
struct FormatCommands: Commands {
    @FocusedObject private var editor: EditorController?
    @FocusedValue(\.editorModeSwitch) private var switchMode
    @FocusedValue(\.inspectorToggle) private var toggleInspector

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Divider()
            ActionMenuItems(actions: [.exportPDF, .exportHTML], editor: editor)
        }
        CommandGroup(before: .toolbar) {
            Button("单页", systemImage: "doc.richtext") { switchMode?(.rich) }
                .keyboardShortcut("1")
                .disabled(switchMode == nil)
            Button("双页", systemImage: "rectangle.split.2x1") { switchMode?(.source) }
                .keyboardShortcut("2")
                .disabled(switchMode == nil)
            Button("格式面板", systemImage: "paintbrush") { toggleInspector?() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(toggleInspector == nil)
            AppearanceMenu()
            PageMarginMenu()
            TextScaleMenu()
            SourceMarkMenu()
            Divider()
        }
        CommandMenu("格式") {
            ActionMenuItems(actions: EditorAction.textStyles, editor: editor)
            Menu("更多文字样式") {
                ActionMenuItems(actions: EditorAction.moreTextStyles, editor: editor)
            }
            Divider()
            Menu("段落样式") {
                ActionMenuItems(actions: EditorAction.paragraphStyles.filter { $0 != .codeBlock }, editor: editor, icons: false)
            }
            codeBlockMenu
            Divider()
            ActionMenuItems(actions: EditorAction.lists, editor: editor)
        }
        CommandMenu("插入") {
            ForEach(Array(EditorAction.insertGroups.enumerated()), id: \.offset) { i, group in
                if i > 0 { Divider() }
                if group.contains(.details) {
                    calloutMenu
                    codeBlockMenu
                }
                ActionMenuItems(actions: group, editor: editor)
            }
        }
    }

    private var calloutMenu: some View {
        Menu("提示框", systemImage: EditorAction.callout.symbol) {
            ForEach(MDCallout.allCases, id: \.self) { c in
                Button(c.title) { editor?.callout(c) }.disabled(editor == nil)
            }
        }
    }

    private var codeBlockMenu: some View {
        Menu("代码块", systemImage: EditorAction.codeBlock.symbol) {
            ActionMenuItems(actions: [.codeBlock], editor: editor)
            Divider()
            ForEach(codeLanguages, id: \.self) { lang in
                Button(lang) { editor?.codeBlock(lang) }.disabled(editor == nil)
            }
        }
    }
}

/// 帮助文档：复制到缓存目录后用编辑器打开（避免修改 App 包内的文件）
enum HelpDocs {
    private static func openCopy(of name: String) {
        guard let src = Bundle.main.resourceURL?.appendingPathComponent(name),
              FileManager.default.fileExists(atPath: src.path) else { return }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DropMD", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dst)
        guard (try? FileManager.default.copyItem(at: src, to: dst)) != nil else { return }
        NSDocumentController.shared.openDocument(withContentsOf: dst, display: true) { _, _, _ in }
    }

    // 文件名也随界面语言：英文界面打开 User Guide.md，日文 ユーザーガイド.md，繁体 使用說明.md（都在 App 包里）
    static func openGuide() { openCopy(of: String(localized: "使用说明.md")) }

    /// 第一次打开 DropMD 时（从旧版本升级后的第一次也算）自动打开使用说明，只打开一次
    @MainActor static func openGuideOnFirstLaunch() {
        let key = "shownUserGuide"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        openGuide()
    }

    /// GitHub 仓库网页（仓库名取自 Info.plist，和软件更新同一处）
    @MainActor static func repoURL(path: String = "") -> URL? {
        UpdateChecker.repository.flatMap { URL(string: "https://github.com/\($0)\(path)") }
    }
    /// Discord 社区（永久邀请链接）
    static let discord = URL(string: "https://discord.gg/VUne62RvrJ")!
    /// QQ 交流群（群号 1125893504），只在中文界面显示
    static let qqGroup = URL(string: "https://qun.qq.com/universal-share/share?ac=1&authKey=mbUgS60nnSzR2inccSoO%2BM4r%2BNMmccWLqCLkRWF%2F3aaEx%2FCX30Fizgha%2Fo6qaAvV&busi_data=eyJncm91cENvZGUiOiIxMTI1ODkzNTA0IiwidG9rZW4iOiJkQ1NySUpoeCtmTUlrV3JUWUN5SFZqNU5wZllLa2lFLzFrUjZMKzdnaXV0eUM1R001ZzMzb1ZFOXNTbFNudFVPIiwidWluIjoiMzI0MzY3NzM1MiJ9&data=AJTczm17mcBKqj3VXo3mcTEzkLtb9_ozC8vIN86Zcm8p_2cQJ63-BoTHLDlRXXAZ9OTuDjY1Rqekn1E_zbQZfA&svctype=4&tempid=h5_group_info")!
    static var showsQQGroup: Bool { (Bundle.main.preferredLocalizations.first ?? "").hasPrefix("zh") }

    /// 赞助：爱发电和 Patreon，所有语言都显示（爱发电已支持英文和海外付款，非中文界面叫 Afdian）。中文界面爱发电在前
    struct Sponsor { let name: String; let menuTitle: String; let url: URL }
    static var sponsors: [Sponsor] {
        let patreon = Sponsor(name: "Patreon", menuTitle: String(localized: "在 Patreon 赞助…"),
                              url: URL(string: "https://www.patreon.com/c/katsurama/membership")!)
        let afdian = Sponsor(name: String(localized: "爱发电"), menuTitle: String(localized: "在爱发电赞助…"),
                             url: URL(string: "https://afdian.com/a/katsurama")!)
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        return lang.hasPrefix("zh") ? [afdian, patreon] : [patreon, afdian]
    }

    /// 微信赞赏码（App 包里的图片）：只在中文界面显示
    static var wechatQR: NSImage? {
        guard (Bundle.main.preferredLocalizations.first ?? "").hasPrefix("zh"),
              let url = Bundle.main.url(forResource: "wechat-sponsor", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

}

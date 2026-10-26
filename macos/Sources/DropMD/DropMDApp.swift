import AppKit
import SwiftUI

@main
struct DropMDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var converter = AppModel()

    var body: some Scene {
        // 主功能：Markdown 编辑器（新建、打开、自动保存、版本历史由系统文档机制提供）
        DocumentGroup(newDocument: MarkdownDocument()) { file in
            EditorView(document: file.$document, fileURL: file.fileURL)
        }
        .defaultSize(width: 980, height: 660)
        .commands {
            CommandGroup(after: .appInfo) {
                OpenUpdatesButton()
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
                        if let dir = converter.engineStatus?.modelsDir {
                            let url = URL(fileURLWithPath: dir)
                            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            FormatCommands()
            CommandGroup(replacing: .help) {
                Button("使用说明") { HelpDocs.openGuide() }
                Button("隐私说明") {
                    let a = NSAlert()
                    a.messageText = "隐私说明"
                    a.informativeText = privacyText
                    a.addButton(withTitle: "好")
                    a.runModal()
                }
                Divider()
                Menu("开源许可") {
                    Button("DropMD（MIT 许可证）") { HelpDocs.openAppLicense() }
                    Button("第三方组件") { HelpDocs.openLicenses() }
                }
            }
        }

        // 文件转换（从“文件”菜单或工具栏打开）
        Window("转换为 Markdown", id: "converter") {
            ContentView()
                .environmentObject(converter)
        }
        .defaultSize(width: 1060, height: 720)

        // 软件更新（菜单“DropMD → 检查更新…”）
        Window("软件更新", id: "updates") {
            UpdateView(updater: UpdateChecker.shared)
        }
        .windowResizability(.contentSize)
    }
}

/// 外观：跟随系统 / 浅色 / 深色（保存在偏好设置的 appearance 中）
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppAppearance.apply(UserDefaults.standard.string(forKey: "appearance")) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 等文档窗口出现后再检查，避免与“打开文件”面板同时弹出
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated { UpdateChecker.shared.launchCheck() }
        }
    }
}

/// “DropMD → 检查更新…”
struct OpenUpdatesButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("检查更新…") { openWindow(id: "updates") }
            .onReceive(NotificationCenter.default.publisher(for: .showUpdates)) { _ in
                openWindow(id: "updates")
            }
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
            Button("单页") { switchMode?(.rich) }
                .keyboardShortcut("1")
                .disabled(switchMode == nil)
            Button("双页") { switchMode?(.source) }
                .keyboardShortcut("2")
                .disabled(switchMode == nil)
            Button("格式面板") { toggleInspector?() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(toggleInspector == nil)
            AppearanceMenu()
            Divider()
        }
        CommandMenu("格式") {
            ActionMenuItems(actions: EditorAction.textStyles, editor: editor)
            Menu("更多文字样式") {
                ActionMenuItems(actions: EditorAction.moreTextStyles, editor: editor)
            }
            Divider()
            Menu("段落样式") {
                ActionMenuItems(actions: EditorAction.paragraphStyles.filter { $0 != .codeBlock }, editor: editor)
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
        Menu("提示框") {
            ForEach(MDCallout.allCases, id: \.self) { c in
                Button(c.title) { editor?.callout(c) }.disabled(editor == nil)
            }
        }
    }

    private var codeBlockMenu: some View {
        Menu("代码块") {
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
    private static func openCopy(of name: String, as copyName: String? = nil) {
        guard let src = Bundle.main.resourceURL?.appendingPathComponent(name),
              FileManager.default.fileExists(atPath: src.path) else { return }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DropMD", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(copyName ?? name)
        try? FileManager.default.removeItem(at: dst)
        guard (try? FileManager.default.copyItem(at: src, to: dst)) != nil else { return }
        NSDocumentController.shared.openDocument(withContentsOf: dst, display: true) { _, _, _ in }
    }

    static func openGuide() { openCopy(of: "使用说明.md") }
    static func openLicenses() { openCopy(of: "THIRD_PARTY_LICENSES.md") }
    static func openAppLicense() { openCopy(of: "LICENSE", as: "DropMD 许可证.md") }
}

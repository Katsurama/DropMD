import SwiftUI

/// 设置的“更新”页（菜单“检查更新…”打开这一页）
struct UpdateView: View {
    @ObservedObject var updater: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("软件更新").font(.title2.weight(.semibold))
                    Text("当前版本：\(UpdateChecker.currentVersionText)")
                        .foregroundStyle(.secondary)
                    if let last = updater.lastChecked {
                        Text("上次检查：\(last.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("立即检查") { Task { await updater.check() } }
                    .disabled(busy || UpdateChecker.repository == nil)
            }

            status

            Divider()

            Toggle("启动时自动检查更新", isOn: $updater.autoCheck)
            Toggle("包括测试版（beta）", isOn: $updater.includeBeta)

            Text("检查更新只向 GitHub 查询版本信息，不发送任何文件或个人信息。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var busy: Bool {
        [.checking, .downloading, .installing, .readyToRestart].contains(updater.state)
    }

    @ViewBuilder
    private var status: some View {
        switch updater.state {
        case .idle:
            if UpdateChecker.repository == nil {
                Label("此版本没有更新来源。", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            } else {
                Label("尚未检查。", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            }
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在检查…")
            }
        case .upToDate:
            Label("已是最新版本。", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .available, .downloading, .installing, .readyToRestart, .downloaded:
            if let release = updater.latest {
                releaseBox(release)
            }
        case .failed(let message):
            Label("检查或下载失败：\(message)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func releaseBox(_ release: ReleaseInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("新版本：\(release.version?.description ?? release.tagName)", systemImage: "sparkles")
                    .font(.headline)
                if release.prerelease {
                    Text("测试版")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                }
                Spacer()
                Button("在浏览器中查看") { NSWorkspace.shared.open(release.htmlUrl) }
                    .buttonStyle(.link)
            }
            // 说明占满页面剩下的高度；再长也只在这一框里滚动，下面的按钮和开关不动
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(noteLines(release).enumerated()), id: \.offset) { _, line in
                        noteLine(line)
                    }
                }
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(12)
            }
            .frame(minHeight: 140, maxHeight: .infinity)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            switch updater.state {
            case .downloading:
                HStack {
                    ProgressView(value: updater.progress)
                    Button("取消") { updater.cancelDownload() }
                }
            case .installing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在准备新版本…")
                }
            case .readyToRestart:
                HStack {
                    Label("新版本已准备好。", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("重新启动") { updater.restartToUpdate() }
                        .keyboardShortcut(.defaultAction)
                }
            case .downloaded(let file, let reason):
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("请把 DropMD 拖到“应用程序”。", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
            default:
                HStack {
                    Spacer()
                    Button(release.dmg == nil ? String(localized: "前往下载页面") : String(localized: "下载并更新")) { updater.downloadLatest() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// 界面语言那一段说明，拆成一行一行
    private func noteLines(_ release: ReleaseInfo) -> [ReleaseNoteLine] {
        let ui = Bundle.main.preferredLocalizations.first ?? ""
        let lang = ui.hasPrefix("zh-Hant") ? "zh-Hant" : ui.hasPrefix("zh") ? "zh" : ui.hasPrefix("ja") ? "ja" : "en"
        guard let body = release.body else { return [.text(String(localized: "（没有更新说明）"))] }
        return releaseNoteLines(releaseNotes(body, language: lang))
    }

    /// 行内的粗体、链接等照常显示
    private func inline(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    }

    @ViewBuilder
    private func noteLine(_ line: ReleaseNoteLine) -> some View {
        switch line {
        case .heading(let s):
            Text(inline(s)).font(.headline).padding(.top, 2)
        case .bullet(let level, let s):
            // 圆点和文字分开排：文字折行时第二行和第一行的字对齐
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                Text(inline(s)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(level) * 16)
        case .text(let s):
            Text(inline(s))
        case .blank:
            Spacer().frame(height: 4)
        }
    }
}

import SwiftUI

/// “软件更新”窗口
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

            Toggle("自动检查更新（每天最多一次）", isOn: $updater.autoCheck)
            Toggle("包括测试版（beta）", isOn: $updater.includeBeta)

            Text("检查更新只向 GitHub 查询版本信息，不发送任何文件或个人信息。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 520)
        // 窗口高度始终等于内容高度：内容变化（如发现新版本）时窗口跟着变大，不用手动拉
        .fixedSize(horizontal: false, vertical: true)
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
            ScrollView {
                Text(notes(release))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(height: 140)
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
            case .downloaded(let file):
                HStack {
                    Label("请把 DropMD 拖到“应用程序”。", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
            default:
                HStack {
                    Spacer()
                    Button(release.dmg == nil ? "前往下载页面" : "下载并更新") { updater.downloadLatest() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func notes(_ release: ReleaseInfo) -> AttributedString {
        let body = release.body ?? "（没有更新说明）"
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: body, options: options)) ?? AttributedString(body)
    }
}

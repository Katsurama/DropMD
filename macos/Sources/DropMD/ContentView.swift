import SwiftUI
import UniformTypeIdentifiers

let privacyText = """
所有转换都在这台 Mac 上完成，文件不会上传。

• 只在您同意时联网：下载识别模型、检查更新。
• 没有统计或广告。
• 不修改原始文件。
"""

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection = Set<FileItem.ID>()
    @State private var dropTargeted = false
    @State private var showPrivacy = false

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 16) {
                    dropZone
                    fileList
                }
                settings
                    .frame(width: 320)
            }
            bottomBar
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(minWidth: 860, minHeight: 560)
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .task { await model.loadStatus() }
        // 系统标准的工具栏：窗口标题在左，隐私说明在右
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showPrivacy = true } label: {
                    Label("本机离线处理", systemImage: "lock.shield")
                        .labelStyle(.titleAndIcon)
                }
                .help("隐私说明")
            }
        }
        .alert("隐私说明", isPresented: $showPrivacy) {
            Button("好", role: .cancel) {}
        } message: {
            Text(privacyText)
        }
    }

    // MARK: 拖放区

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 56, height: 56)
                .background(Color.accentColor.opacity(dropTargeted ? 0.25 : 0.12),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .symbolEffect(.bounce, value: dropTargeted)
            Text("拖入文件或文件夹")
                .font(.title3.weight(.semibold))
            Text("Word · Excel · PowerPoint · HTML · PDF · CSV")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("选择文件…") { model.chooseFiles() }
                    .glassButton()
                Button("选择文件夹…") { model.chooseFolder() }
                    .glassButton()
            }
            .controlSize(.large)
            .padding(.top, 4)
            .disabled(model.running)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .padding(8)
        )
        .background(Color.accentColor.opacity(dropTargeted ? 0.08 : 0),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .glassCard()
        .animation(.smooth(duration: 0.2), value: dropTargeted)
    }

    // MARK: 文件列表

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("文件").font(.headline)
                if !model.items.isEmpty {
                    Text("\(model.items.count) 个").foregroundStyle(.secondary)
                }
                Spacer()
                Button("移除所选") {
                    model.remove(selection)
                    selection.removeAll()
                }
                .buttonStyle(.borderless)
                .disabled(selection.isEmpty || model.running)
                Button("清空") { model.clear() }
                    .buttonStyle(.borderless)
                    .disabled(model.items.isEmpty || model.running)
            }
            if model.items.isEmpty {
                ContentUnavailableView {
                    Label("尚未添加文件", systemImage: "doc.text")
                } description: {
                    Text("转换完成后，双击列表中的文件即可用编辑器打开")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.items, selection: $selection) {
                    TableColumn("名称") { item in
                        Text(item.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(item.url.path)
                    }
                    .width(min: 140, ideal: 220)
                    TableColumn("状态") { item in
                        StatusPill(status: item.status)
                    }
                    .width(76)
                    TableColumn("说明") { item in
                        Text(item.info)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(item.status == .failed ? Color.red : Color.secondary)
                            .help(item.info)
                    }
                }
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: FileItem.ID.self) { ids in
                    Button("用编辑器打开") { model.openInEditor(ids) }
                    Button("在访达中显示") { model.reveal(ids) }
                    Button("从列表中移除") { model.remove(ids) }
                        .disabled(model.running)
                } primaryAction: { ids in
                    model.openInEditor(ids)
                }
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity)
        .glassCard()
    }

    // MARK: 设置

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("转换设置").font(.headline)

            row("模式") {
                Picker("模式", selection: $model.mode) {
                    ForEach(ConvertMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Text(model.mode == .hq
                 ? "适合论文、扫描版 PDF。只对 PDF 生效。"
                 : "速度快，适合大多数文件。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            row("Word 引擎") {
                Picker("Word 引擎", selection: $model.wordEngine) {
                    ForEach(WordEngine.allCases) { e in
                        Text(e.label).tag(e)
                            .disabled(e == .pandoc && !model.pandocAvailable)
                    }
                }
                .labelsHidden()
                .help("Pandoc 还原排版更好，并导出图片")
            }

            if model.mode == .hq {
                row("OCR 引擎") {
                    Picker("OCR 引擎", selection: $model.ocrEngine) {
                        ForEach(model.ocrEngines, id: \.self) { Text(ocrEngineNames[$0] ?? $0).tag($0) }
                    }
                    .labelsHidden()
                }
                if model.ocrEngine == "vision" {
                    row("主要语言") {
                        Picker("主要语言", selection: $model.visionLang) {
                            ForEach(visionLanguages) { Text($0.name).tag($0.code) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    Text("中日文混合时请用 RapidOCR。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("中日英混合识别，无需下载。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle(isOn: $model.formulas) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("识别数学公式")
                        Text("较慢，需下载模型").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }

            Divider()

            row("输出位置") {
                Picker("输出位置", selection: $model.outputCustom) {
                    Text("原文件夹").tag(false)
                    Text("指定文件夹").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if model.outputCustom {
                HStack(spacing: 6) {
                    Text(model.customDir?.path ?? "（未选择）")
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .help(model.customDir?.path ?? "")
                    Button("选择…") { model.chooseOutputDir() }
                        .buttonStyle(.borderless)
                }
            }
            Text(model.outputCustom ? "输出到指定文件夹（拖入文件夹时保留子目录结构）"
                                    : "保存在原文件旁边，文件名相同，扩展名为 .md")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .disabled(model.running)
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassCard()
        .animation(.smooth(duration: 0.2), value: model.mode)
        .animation(.smooth(duration: 0.2), value: model.outputCustom)
        .animation(.smooth(duration: 0.2), value: model.ocrEngine)
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            content()
        }
    }

    // MARK: 底部操作栏

    private var bottomBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressView(value: min(model.progress, model.progressTotal), total: max(model.progressTotal, 1))
                    .progressViewStyle(.linear)
            }
            Button("停止") { model.stop() }
                .glassButton()
                .controlSize(.large)
                .disabled(!model.running)
            Button {
                Task { await model.start() }
            } label: {
                Text("开始转换").frame(minWidth: 88)
            }
            .glassProminentButton()
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.running)
        }
    }
}

struct StatusPill: View {
    let status: ItemStatus

    var body: some View {
        HStack(spacing: 4) {
            if status == .running {
                ProgressView().controlSize(.mini)
            }
            Text(status.label)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(status.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(status.color.opacity(0.15), in: Capsule())
    }
}

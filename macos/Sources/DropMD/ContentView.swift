import SwiftUI
import UniformTypeIdentifiers

let privacyText = String(localized: """
文件转换全程在这台 Mac 上完成，不会上传源文件。

• DropMD 的文档智能功能默认为“自动”：处理长文档时，相关内容可能发送给 Apple 私有云计算；可在设置中改为“仅本机”。系统写作工具等由 macOS 管理，不受此选项控制。
• 经您同意后，可联网下载识别模型或检查更新。
• 没有统计或广告；转换不修改原始文件。
""")

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection = Set<FileItem.ID>()
    @State private var dropTargeted = false
    @State private var showPrivacy = false

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 12) {
                    if model.items.isEmpty {
                        dropZone(compact: false)
                    } else {
                        dropZone(compact: true)
                        fileList
                    }
                }
                .animation(.smooth(duration: 0.2), value: model.items.isEmpty)
                settings
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
            Button("确认", role: .cancel) {}
        } message: {
            Text(privacyText)
        }
    }

    // MARK: 拖放区

    @ViewBuilder
    private func dropZone(compact: Bool) -> some View {
        Group {
            if compact {
                HStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor.opacity(dropTargeted ? 0.25 : 0.12),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("拖入文件或文件夹")
                            .font(.subheadline.weight(.semibold))
                        Text("Word · Excel · PowerPoint · HTML · PDF · CSV")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Button("选择文件…") { model.chooseFiles() }
                            .glassButton()
                        Button("选择文件夹…") { model.chooseFolder() }
                            .glassButton()
                    }
                    .controlSize(.regular)
                    .disabled(model.running)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 60, height: 60)
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
                    Spacer(minLength: 0)
                    Text("双击列表中的文件，可在编辑器中打开")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: compact ? 14 : 18, style: .continuous)
                .strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(compact ? 0.25 : 0.35),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .padding(compact ? 6 : 8)
        )
        .background(Color.accentColor.opacity(dropTargeted ? 0.08 : 0),
                    in: RoundedRectangle(cornerRadius: compact ? 18 : 22, style: .continuous))
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: compact ? 18 : 22, style: .continuous))
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
                Button("清空") {
                    model.clear()
                    selection.removeAll()
                }
                .buttonStyle(.borderless)
                .disabled(model.items.isEmpty || model.running)
            }
            List(model.items, selection: $selection) { item in
                FileRowView(
                    item: item,
                    running: model.running,
                    onOpen: { model.openInEditor([item.id]) },
                    onReveal: { model.reveal([item.id]) },
                    onRemove: {
                        selection.remove(item.id)
                        model.remove([item.id])
                    }
                )
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: FileItem.ID.self) { ids in
                Button("用编辑器打开") { model.openInEditor(ids) }
                Button("在访达中显示") { model.reveal(ids) }
                Button("从列表中移除") {
                    selection.subtract(ids)
                    model.remove(ids)
                }
                    .disabled(model.running)
            } primaryAction: { ids in
                model.openInEditor(ids)
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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
                 ? String(localized: "适合论文、扫描版 PDF。只对 PDF 生效。")
                 : String(localized: "速度快，适合大多数文件。"))
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
                .help("Pandoc 还原排版更好；两种引擎都会导出图片")
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
                } else if model.ocrEngine == "xiaomi" {
                    Text("公式和表格一起识别。需下载约 1.8 GB，不导出 PDF 里的图片，韩文和越南文错字较多。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("中日英混合识别，无需下载。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.ocrEngine != "xiaomi" {
                    Toggle(isOn: $model.formulas) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("识别数学公式")
                            Text("较慢，需下载模型").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }
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
                    Text(model.customDir?.path ?? String(localized: "（未选择）"))
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
            Text(model.outputCustom ? String(localized: "拖入文件夹时，保留里面的子文件夹结构")
                                    : String(localized: "保存在原文件旁边，同名的 .md 文件"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .disabled(model.running)
        .padding(20)
        .frame(width: 364)   // 限制要在卡片里面：写在外面时，放不下的内容会把卡片撑大，盖住左边
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.smooth(duration: 0.2), value: model.mode)
        .animation(.smooth(duration: 0.2), value: model.outputCustom)
        .animation(.smooth(duration: 0.2), value: model.ocrEngine)
    }

    private func row<C: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> C) -> some View {
        // 译文太长、一行放不下时，标签和控件改成上下排
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)
                content()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).foregroundStyle(.secondary)
                content()
            }
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
                if model.running {
                    ProgressView(value: min(model.progress, model.progressTotal), total: max(model.progressTotal, 1))
                        .progressViewStyle(.linear)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.running {
                Button { model.stop() } label: {
                    Text("停止").frame(minWidth: 88)
                }
                .tint(.red)
                .glassProminentButton()
                .controlSize(.large)
            } else {
                Button {
                    Task { await model.start() }
                } label: {
                    Text("开始转换").frame(minWidth: 88)
                }
                .glassProminentButton()
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .animation(.smooth(duration: 0.2), value: model.running)
    }
}

private struct FileRowView: View {
    let item: FileItem
    let running: Bool
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void
    @State private var hovered = false

    private var iconStyle: (symbol: String, color: Color) {
        switch item.url.pathExtension.lowercased() {
        case "pdf": return ("doc.text", .red)
        case "docx": return ("doc.richtext", .blue)
        case "xlsx", "csv": return ("tablecells", .green)
        case "pptx": return ("play.rectangle", .orange)
        case "html", "htm": return ("globe", .cyan)
        default: return ("doc", .secondary)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconStyle.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(iconStyle.color)
                .frame(width: 28, height: 28)
                .background(iconStyle.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.url.path)
                if !item.info.isEmpty {
                    Text(item.info)
                        .font(.caption)
                        .foregroundStyle(item.status == .failed ? Color.red : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(item.info)
                }
            }
            Spacer(minLength: 8)
            if hovered {
                HStack(spacing: 4) {
                    Button(action: onOpen) { Image(systemName: "doc.text.magnifyingglass") }
                        .help("用编辑器打开")
                    Button(action: onReveal) { Image(systemName: "folder") }
                        .help("在访达中显示")
                    Button(action: onRemove) { Image(systemName: "xmark") }
                        .help("从列表中移除")
                        .disabled(running)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .controlSize(.small)
            }
            StatusPill(status: item.status)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
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

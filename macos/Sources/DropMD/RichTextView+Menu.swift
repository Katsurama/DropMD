import AppKit

extension RichTextView {
    // MARK: - 右键菜单：放工具栏上没有的、常用但不好点到的操作，跟着点中的东西变



    override func rightMouseDown(with event: NSEvent) {
        selectionBeforeMenu = selectedRange()
        super.rightMouseDown(with: event)
        selectionBeforeMenu = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let before = selectionBeforeMenu ?? selectedRange()
        let menu = super.menu(for: event) ?? NSMenu()
        removeSystemLinkItems(menu)
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        // 点在自己选的字上：保留选区；否则光标移到点的地方（不用系统自动选中的词）
        if before.length > 0, NSLocationInRange(index, before) || index == NSMaxRange(before) {
            setSelectedRange(before)
        } else {
            setSelectedRange(NSRange(location: index, length: 0))
        }
        // 点中的那个字（链接、图片要看点中的字，不是光标后面的字）
        var hit = index
        if let lm = layoutManager, let container = textContainer, lm.numberOfGlyphs > 0 {
            let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
            hit = lm.characterIndex(for: p, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        }
        let items = contextItems(hit: hit)
        for (i, item) in (items.isEmpty ? [] : items + [NSMenuItem.separator()]).enumerated() {
            if item.target == nil, !item.isSeparatorItem { item.target = self }
            menu.insertItem(item, at: i)
        }
        return menu
    }

    /// 去掉系统菜单里用不上的项：
    /// 链接的几项改的是系统的链接记号，保存时不认（用 DropMD 自己的）；字体、文字方向、快速查看附件 Markdown 存不下来
    private func removeSystemLinkItems(_ menu: NSMenu) {
        let names: Set<String> = ["_openLinkFromMenu:", "copyLink:", "orderFrontLinkPanel:", "_removeLinkFromMenu:", "toggleQuickLookPreviewPanel:"]
        let subPrefixes = ["orderFrontFontPanel", "addFontTrait", "changeLayoutOrientation", "makeBaseWritingDirection", "makeTextWritingDirection"]
        var i = 0
        while i < menu.items.count {
            let item = menu.items[i]
            let name = item.action.map { NSStringFromSelector($0) } ?? ""
            let subActions = item.submenu?.items.compactMap { $0.action.map { NSStringFromSelector($0) } } ?? []
            if subActions.contains(where: { a in subPrefixes.contains { a.hasPrefix($0) } }) {
                menu.removeItem(at: i)
                continue
            }
            if names.contains(name) {
                menu.removeItem(at: i)
                // 紧跟在“打开链接”后面的“打开方式”子菜单
                if name == "_openLinkFromMenu:", i < menu.items.count, menu.items[i].submenu != nil { menu.removeItem(at: i) }
                continue
            }
            i += 1
        }
        // 去掉连在一起的、开头的分隔线
        i = 0
        while i < menu.items.count {
            if menu.items[i].isSeparatorItem, i == 0 || menu.items[i - 1].isSeparatorItem { menu.removeItem(at: i) } else { i += 1 }
        }
    }

    private func menuItem(_ title: String, _ action: Selector?, _ object: Any? = nil, on: Bool = false) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: action, keyEquivalent: "")
        m.representedObject = object
        m.state = on ? .on : .off
        m.target = self
        return m
    }

    private func actionItem(_ action: EditorAction, title: String? = nil, on: Bool = false) -> NSMenuItem {
        menuItem(title ?? action.menuTitle, #selector(runEditorAction(_:)), action.rawValue, on: on)
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        items.forEach { sub.addItem($0) }
        m.submenu = sub
        return m
    }

    /// 右键菜单最上面的几组（组与组之间加分隔线）
    func contextItems(hit: Int) -> [NSMenuItem] {
        guard let storage = textStorage else { return [] }
        let sel = selectedRange()
        var groups: [[NSMenuItem]] = []
        if sel.length > 0 {
            let active = selectionState.active
            var selectionGroup = [actionItem(.strike, on: active.contains(.strike)), actionItem(.highlight, on: active.contains(.highlight)),
                                  actionItem(.inlineCode, on: active.contains(.inlineCode)),
                                  menuItem(String(localized: "清除格式"), #selector(clearFormatting(_:)))]
            if SiriAIManager.isTranslationAvailable {
                selectionGroup.append(menuItem(String(localized: "翻译所选内容…"), #selector(translateSelectedText(_:))))
            }
            groups.append(selectionGroup)
        }
        if hit < storage.length {
            let a = storage.attributes(at: hit, effectiveRange: nil)
            if a[DMKey.image] != nil {
                let r = objectRange(at: hit) ?? NSRange(location: hit, length: 1)   // 显示出来的图片是一个附件字符
                let path = a[DMKey.image] as? String ?? ""
                let file = imageFile(path)
                let isHTMLBlock = a[DMKey.htmlRaw] != nil
                var items: [NSMenuItem] = []
                if !isHTMLBlock {
                    items.append(menuItem(String(localized: "编辑替代文本…"), #selector(editImageAlt(_:)), NSValue(range: r)))
                }
                items.append(menuItem(String(localized: "提取图片中的文字"), file == nil ? nil : #selector(extractImageText(_:)), NSValue(range: r)))
                items.append(menuItem(String(localized: "在访达中显示"), file == nil ? nil : #selector(revealImage(_:)), file))
                if !isHTMLBlock {
                    items.append(menuItem(String(localized: "删除图片"), #selector(deleteImage(_:)), NSValue(range: r)))
                }
                groups.append(items)
            } else if let url = a[DMKey.link] as? String {
                var r = NSRange()
                storage.attribute(DMKey.link, at: hit, longestEffectiveRange: &r, in: NSRange(location: 0, length: storage.length))
                groups.append([menuItem(String(localized: "打开链接"), #selector(openLinkItem(_:)), url),
                               menuItem(String(localized: "编辑链接…"), #selector(editLink(_:)), NSValue(range: r)),
                               menuItem(String(localized: "复制链接"), #selector(copyLinkAddress(_:)), url),
                               menuItem(String(localized: "移除链接"), #selector(removeLink(_:)), NSValue(range: r))])
            }
        }
        let at = selectedRange().location
        let lm = layoutManager as? RichLayoutManager
        if cell(at: at) != nil, let ctx = tableContext() {
            groups += tableItems(ctx)
        } else if case .code(let lang) = currentKind, at < storage.length {   // 原样保存的段落（YAML、HTML）不算代码块
            groups.append([menuItem(String(localized: "复制代码"), #selector(copyCode(_:))),
                           submenu(String(localized: "语言"), ([""] + codeLanguages).map {
                               menuItem($0.isEmpty ? String(localized: "纯文本") : $0, #selector(setCodeLanguage(_:)), $0, on: $0 == lang)
                           })])
        } else if storage.length > 0, let type = lm?.callout(at: min(at, storage.length - 1), in: storage) {
            groups.append([submenu(String(localized: "提示框类型"), MDCallout.allCases.map {
                               menuItem($0.title, #selector(setCalloutType(_:)), $0.rawValue, on: $0 == type)
                           }),
                           menuItem(String(localized: "转换为引用"), #selector(removeCallout(_:)))])
        } else if currentKind.isList {
            groups.append([actionItem(.indent), actionItem(.outdent)])
        } else if sel.length == 0 {
            let kind = currentKind
            let kinds: [(EditorAction, RichKind)] = [(.body, .body), (.heading1, .heading(1)), (.heading2, .heading(2)),
                                                     (.heading3, .heading(3)), (.quote, .quote)]
            groups.append([
                submenu(String(localized: "转换为"), kinds.map { actionItem($0.0, on: kind == $0.1) } + [actionItem(.codeBlock)]),
                submenu(String(localized: "插入"), [actionItem(.rule),
                    submenu(EditorAction.callout.title, MDCallout.allCases.map { menuItem($0.title, #selector(insertCalloutItem(_:)), $0.rawValue) }),
                    actionItem(.details), actionItem(.mathBlock), actionItem(.date)]),
            ])
        }
        return groups.filter { !$0.isEmpty }.reduce([NSMenuItem]()) { $0.isEmpty ? $1 : $0 + [NSMenuItem.separator()] + $1 }
    }

    /// 表格的操作：行、列、这一列的对齐、复制 / 删除表格
    private func tableItems(_ ctx: (range: NSRange, row: Int, column: Int, columns: Int)) -> [[NSMenuItem]] {
        let current = tableColumnMarker()
        return [
            // 表头上面不能再插一行（第一行总是表头）
            [menuItem(String(localized: "在上方插入行"), ctx.row > 0 ? #selector(insertTableRowAbove(_:)) : nil),
             menuItem(String(localized: "在下方插入行"), #selector(insertTableRowBelow(_:))),
             menuItem(String(localized: "删除行"), ctx.row > 0 ? #selector(deleteTableRow(_:)) : nil)],
            [menuItem(String(localized: "在左侧插入列"), #selector(insertTableColumnLeft(_:))),
             menuItem(String(localized: "在右侧插入列"), #selector(insertTableColumnRight(_:))),
             menuItem(String(localized: "删除列"), ctx.columns > 1 ? #selector(deleteTableColumn(_:)) : nil)],
            [submenu(String(localized: "对齐方式"), [(String(localized: "左对齐"), ":--"), (String(localized: "居中对齐"), ":-:"), (String(localized: "右对齐"), "--:")].map {
                menuItem($0.0, #selector(alignTableColumn(_:)), $0.1, on: current == $0.1)
            }),
             menuItem(String(localized: "复制表格"), #selector(copyTable(_:))),
             menuItem(String(localized: "删除表格"), #selector(deleteTable(_:)))],
        ]
    }

    @objc func runEditorAction(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String, let action = EditorAction(rawValue: raw) else { return }
        onAction?(action)
    }

    /// 去掉选中文字的粗体、斜体、下划线、删除线、高亮、行内代码、上下标、按键；链接、图片、公式不动
    @objc func clearFormatting(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0 else { return }
        changeAttributes(in: range) { a in
            if a[DMKey.image] != nil || a[DMKey.math] != nil || a[DMKey.literal] != nil { return a }
            var b = a
            for key in [DMKey.inlineCode, DMKey.kbd, DMKey.highlight] { b[key] = nil }
            for key: NSAttributedString.Key in [.backgroundColor, .superscript, .obliqueness, .strikethroughStyle] { b[key] = nil }
            if b[DMKey.link] == nil {
                b[.underlineStyle] = nil
                b[.underlineColor] = nil
                b[.foregroundColor] = RichStyle.textColor(for: RichBridge.kind(of: b))
            }
            b[.font] = RichStyle.baseFont(for: RichBridge.kind(of: b))
            return b
        }
    }

    @objc func openLinkItem(_ sender: Any?) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? String else { return }
        onOpenLink?(url)
    }

    @objc func editLink(_ sender: Any?) {
        guard let r = ((sender as? NSMenuItem)?.representedObject as? NSValue)?.rangeValue else { return }
        setSelectedRange(r)
        onAction?(.link)
    }

    @objc func copyLinkAddress(_ sender: Any?) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc func removeLink(_ sender: Any?) {
        guard let r = ((sender as? NSMenuItem)?.representedObject as? NSValue)?.rangeValue else { return }
        setSelectedRange(r)
        setLink(nil)
        setSelectedRange(NSRange(location: NSMaxRange(r), length: 0))
    }

    /// 本机图片文件（在线图片、内嵌图片、找不到的文件为 nil）
    private func imageFile(_ path: String) -> URL? {
        let lower = path.lowercased()
        guard !path.isEmpty, !lower.hasPrefix("http:"), !lower.hasPrefix("https:"), !lower.hasPrefix("//"), !lower.hasPrefix("data:") else { return nil }
        let url = URL(fileURLWithPath: path.removingPercentEncoding ?? path, relativeTo: baseURL)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @objc func revealImage(_ sender: Any?) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func deleteImage(_ sender: Any?) {
        guard let r = ((sender as? NSMenuItem)?.representedObject as? NSValue)?.rangeValue else { return }
        replace(r, with: NSAttributedString(), caret: r.location)
        refreshTypingAttributes()
    }

    @objc func editImageAlt(_ sender: Any?) {
        guard let storage = textStorage, let r = ((sender as? NSMenuItem)?.representedObject as? NSValue)?.rangeValue,
              NSMaxRange(r) <= storage.length else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "编辑替代文本")
        alert.informativeText = String(localized: "图片无法显示时显示此文本，读屏软件也会朗读。")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        let initial = storage.attribute(DMKey.alt, at: r.location, effectiveRange: nil) as? String ?? ""
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "确认"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.window.initialFirstResponder = field

        if initial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let path = storage.attribute(DMKey.image, at: r.location, effectiveRange: nil) as? String,
           let file = imageFile(path) {
            DispatchQueue.global(qos: .userInitiated).async { [weak field] in
                guard let ocr = ImageTextExtractor.recognizeText(at: file),
                      let firstLine = ocr.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return }
                let suggestion = String(firstLine.trimmingCharacters(in: .whitespaces).prefix(60))
                DispatchQueue.main.async {
                    guard let field, field.window != nil, field.stringValue.isEmpty else { return }
                    field.stringValue = suggestion
                    field.selectText(nil)
                }
            }
        }

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setImageAlt(field.stringValue, in: r)
    }

    @objc func extractImageText(_ sender: Any?) {
        guard let storage = textStorage, let r = ((sender as? NSMenuItem)?.representedObject as? NSValue)?.rangeValue,
              NSMaxRange(r) <= storage.length,
              let path = storage.attribute(DMKey.image, at: r.location, effectiveRange: nil) as? String,
              let file = imageFile(path) else { return }

        Task.detached(priority: .userInitiated) { [weak self] in
            let extracted = ImageTextExtractor.recognizeText(at: file)
            await MainActor.run { [weak self] in
                guard let self, let storage = self.textStorage, NSMaxRange(r) <= storage.length,
                      (storage.attribute(DMKey.image, at: r.location, effectiveRange: nil) as? String) == path else { return }
                guard let extracted else {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "未在图片中识别到文字")
                    alert.addButton(withTitle: String(localized: "确认"))
                    if let window = self.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(extracted, forType: .string)

                let ns = storage.string as NSString
                let para = ns.paragraphRange(for: r)
                let hasTrailingNewline = para.length > 0 && ns.character(at: NSMaxRange(para) - 1) == 10
                let insertAt = NSMaxRange(para)
                let prefix = hasTrailingNewline ? "" : "\n"
                let bodyAttrs = RichStyle.typingAttributes(for: .body)
                let insertion = NSMutableAttributedString(string: prefix + extracted + "\n", attributes: bodyAttrs)
                self.replace(NSRange(location: insertAt, length: 0), with: insertion, caret: insertAt + insertion.length)
                self.refreshTypingAttributes()
            }
        }
    }

    @objc func translateSelectedText(_ sender: Any?) {
        onAction?(.translateSelection)
    }

    /// 改图片说明：用原来的地址、标题、链接重新生成图片
    func setImageAlt(_ alt: String, in range: NSRange) {
        guard let storage = textStorage, NSMaxRange(range) <= storage.length,
              let path = storage.attribute(DMKey.image, at: range.location, effectiveRange: nil) as? String else { return }
        let a = storage.attributes(at: range.location, effectiveRange: nil)
        let image = NSMutableAttributedString(attributedString: RichBridge.imageString(
            path: path, alt: alt, title: a[DMKey.title] as? String, link: a[DMKey.link] as? String,
            linkTitle: a[DMKey.linkTitle] as? String,
            htmlWidth: a[DMKey.imageWidth] as? String, htmlHeight: a[DMKey.imageHeight] as? String,
            baseURL: baseURL))
        // 段落的属性（列表、表格、折叠块、缩进）照原样补上，否则这一段会变回正文
        var rest = a
        rest[.attachment] = nil
        if let htmlInline = a[DMKey.htmlInline] as? String {
            rest[DMKey.htmlInline] = RichHTML.updatingAlt(in: htmlInline, to: alt)
            rest[DMKey.htmlInlineID] = UUID().uuidString
        }
        for (k, v) in rest where image.attribute(k, at: 0, effectiveRange: nil) == nil {
            image.addAttribute(k, value: v, range: NSRange(location: 0, length: image.length))
        }
        replace(range, with: image, caret: range.location + image.length)
    }

    @objc func copyCode(_ sender: Any?) {
        guard let storage = textStorage, let block = (layoutManager as? RichLayoutManager)?.codeBlock(at: selectedRange().location) else { return }
        var text = (storage.string as NSString).substring(with: block)
        if text.hasSuffix("\n") { text.removeLast() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 整个代码块换成另一种语言（"" 是纯文本），光标不动
    @objc func setCodeLanguage(_ sender: Any?) {
        if let lang = (sender as? NSMenuItem)?.representedObject as? String { setCodeLanguage(to: lang) }
    }

    func setCodeLanguage(to lang: String) {
        guard let block = (layoutManager as? RichLayoutManager)?.codeBlock(at: selectedRange().location) else { return }
        // 只换语言：列表、折叠块等属性和缩进都不动
        changeAttributes(in: block) { old in
            guard old[DMKey.code] != nil else { return old }
            var a = old
            a[DMKey.code] = lang
            return a
        }
    }

    /// 光标所在提示框的标题行（[!NOTE] 那一段）
    private func calloutHeader() -> NSRange? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let ns = storage.string as NSString
        var para = ns.paragraphRange(for: NSRange(location: min(selectedRange().location, storage.length - 1), length: 0))
        while true {
            if storage.attribute(DMKey.callout, at: para.location, effectiveRange: nil) != nil { return para }
            guard para.location > 0 else { return nil }
            let prev = ns.paragraphRange(for: NSRange(location: para.location - 1, length: 0))
            let a = storage.attributes(at: prev.location, effectiveRange: nil)
            guard RichBridge.kind(of: a) == .quote,
                  RichLayoutManager.sameQuote(a, storage.attributes(at: para.location, effectiveRange: nil)) else { return nil }
            para = prev
        }
    }

    @objc func setCalloutType(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String, let type = MDCallout(rawValue: raw),
              let storage = textStorage, let header = calloutHeader() else { return }
        let caret = selectedRange()
        var run = MDRun(text: type.header)
        run.literal = true
        let p = NSMutableAttributedString(attributedString: RichBridge.paragraph(RichBridge.runsString([run], kind: .quote, baseURL: baseURL), kind: .quote))
        let old = storage.attributedSubstring(from: header)
        if !old.string.hasSuffix("\n"), p.string.hasSuffix("\n") { p.deleteCharacters(in: NSRange(location: p.length - 1, length: 1)) }
        if old.length > 0, old.attribute(DMKey.inDetails, at: 0, effectiveRange: nil) != nil { RichBridge.markInDetails(p) }
        if old.length > 0, let id = old.attribute(DMKey.quoteBlock, at: 0, effectiveRange: nil) {   // 还是同一段引用
            p.addAttribute(DMKey.quoteBlock, value: id, range: NSRange(location: 0, length: p.length))
        }
        replace(header, with: p, caret: max(caret.location + p.length - header.length, header.location))   // 换成名字更短的类型时不能小于标题行开头
        refreshTypingAttributes()
    }

    /// 去掉提示框标题行，剩下的内容是普通引用
    @objc func removeCallout(_ sender: Any?) {
        guard let header = calloutHeader() else { return }
        let caret = selectedRange().location
        replace(header, with: NSAttributedString(), caret: max(caret - header.length, header.location))
        refreshTypingAttributes()
    }

    @objc func insertCalloutItem(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String, let type = MDCallout(rawValue: raw) else { return }
        insertCallout(type)
    }
}

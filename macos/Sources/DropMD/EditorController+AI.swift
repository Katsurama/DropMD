import AppKit

#if canImport(ImagePlayground)
import ImagePlayground
#endif

extension EditorController {
    // MARK: - 系统智能：全语言命名 / Spotlight / 翻译 / 智能排版 / 图乐园 / 摘要与问答

    func scheduleTitleAndMetadataUpdate(_ text: String) {
        titleWork?.cancel()
        aiTitleWork?.cancel()

        if fileURL == nil {
            let capturedVersion = editVersion
            let tw = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.fileURL == nil, self.editVersion == capturedVersion else { return }
                    let (fallback, hasHeading) = DocumentTitleSuggester.analyze(from: self.pendingText)
                    if let window = (self.richView ?? self.textView)?.window,
                       let doc = NSDocumentController.shared.document(for: window),
                       doc.fileURL == nil {
                        doc.displayName = fallback
                    }
                    if !hasHeading, #available(macOS 26.0, *), SiriAIManager.isLanguageModelAvailable {
                        let work = DispatchWorkItem { [weak self] in
                            Task { @MainActor [weak self] in
                                guard let self, self.fileURL == nil, self.editVersion == capturedVersion else { return }
                                guard let generated = await DocumentTitleSuggester.aiTitle(from: self.pendingText) else { return }
                                guard self.fileURL == nil, self.editVersion == capturedVersion,
                                      let window = (self.richView ?? self.textView)?.window,
                                      let doc = NSDocumentController.shared.document(for: window),
                                      doc.fileURL == nil else { return }
                                doc.displayName = generated
                            }
                        }
                        self.aiTitleWork = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
                    }
                }
            }
            titleWork = tw
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: tw)
        }

        spotlightWork?.cancel()
        let sw = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let h = self.headings.isEmpty ? extractHeadings(self.pendingText) : self.headings
                let window = (self.richView ?? self.textView)?.window
                SpotlightAndActivity.updateWindowActivity(window: window, url: self.fileURL, text: self.pendingText, headings: h)
                if let url = self.fileURL {
                    SpotlightAndActivity.indexDocument(url: url, text: self.pendingText, headings: h)
                }
            }
        }
        spotlightWork = sw
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: sw)
    }

    func translateSelection() {
        flushPendingEdits()
        if let r = rich {
            let sel = r.selectedRange()
            guard sel.length > 0, let storage = r.textStorage, NSMaxRange(sel) <= storage.length else {
                alert(String(localized: "请先选择要翻译的文字"), String(localized: "在文档中选中一段文字后，再选择“翻译所选内容…”。"))
                return
            }
            let text = (storage.string as NSString).substring(with: sel)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            translationTargetRange = (inRich: true, range: sel)
            translationSourceText = text
            translationPresented = true
            return
        }
        guard let tv = textView else { return }
        let sel = tv.selectedRange()
        let ns = tv.string as NSString
        guard sel.length > 0, NSMaxRange(sel) <= ns.length else {
            alert(String(localized: "请先选择要翻译的文字"), String(localized: "在文档中选中一段文字后，再选择“翻译所选内容…”。"))
            return
        }
        let text = ns.substring(with: sel)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        translationTargetRange = (inRich: false, range: sel)
        translationSourceText = text
        translationPresented = true
    }

    func applyTranslationReplacement(_ translated: String) {
        defer { translationTargetRange = nil }
        guard let target = translationTargetRange else { return }
        if target.inRich {
            guard let r = richView, let storage = r.textStorage,
                  NSMaxRange(target.range) <= storage.length,
                  (storage.string as NSString).substring(with: target.range) == translationSourceText else { return }
            let attrs = target.range.location < storage.length
                ? storage.attributes(at: target.range.location, effectiveRange: nil)
                : r.typingAttributes
            r.replace(target.range, with: NSAttributedString(string: translated, attributes: attrs),
                      caret: target.range.location + (translated as NSString).length)
            r.refreshTypingAttributes()
        } else {
            guard let tv = textView else { return }
            let ns = tv.string as NSString
            guard NSMaxRange(target.range) <= ns.length,
                  ns.substring(with: target.range) == translationSourceText else { return }
            replace(target.range, with: translated)
        }
    }

    private struct AITextTarget {
        let sourceMarkdown: String
        let startSnapshot: String
        let richSelection: NSRange?
        let sourceSelection: NSRange?
        let isFullDocument: Bool
    }

    /// 捕获当前选区（或全篇文档）及其字符快照，确保异步 AI 返回后可安全写回且不破坏撤销栈
    private func captureAITextTarget(requireSelection: Bool, forceFullDocument: Bool = false) -> AITextTarget? {
        if let r = rich, let storage = r.textStorage {
            let sel = r.selectedRange()
            let startSnapshot = storage.string
            if !forceFullDocument, sel.length > 0, NSMaxRange(sel) <= storage.length {
                let sub = storage.attributedSubstring(from: sel)
                let md = MarkdownCodec.serialize(RichBridge.blocks(from: sub))
                let isFull = sel.location == 0 && sel.length == storage.length
                return AITextTarget(sourceMarkdown: md, startSnapshot: startSnapshot, richSelection: sel, sourceSelection: nil, isFullDocument: isFull)
            }
            if requireSelection { return nil }
            let fullRange = NSRange(location: 0, length: storage.length)
            return AITextTarget(sourceMarkdown: pendingText, startSnapshot: startSnapshot, richSelection: fullRange, sourceSelection: nil, isFullDocument: true)
        } else if let tv = textView {
            let sel = tv.selectedRange()
            let ns = tv.string as NSString
            let startSnapshot = tv.string
            if !forceFullDocument, sel.length > 0, NSMaxRange(sel) <= ns.length {
                let md = ns.substring(with: sel)
                let isFull = sel.location == 0 && sel.length == ns.length
                return AITextTarget(sourceMarkdown: md, startSnapshot: startSnapshot, richSelection: nil, sourceSelection: sel, isFullDocument: isFull)
            }
            if requireSelection { return nil }
            let fullRange = NSRange(location: 0, length: ns.length)
            return AITextTarget(sourceMarkdown: tv.string, startSnapshot: startSnapshot, richSelection: nil, sourceSelection: fullRange, isFullDocument: true)
        }
        return nil
    }

    /// 仅返回用户明确选中的局部文字（未选中或已全选整篇时返回 nil，默认按全文摘要，绝不抓取光标所在段落）
    private func selectedTextForSummary() -> String? {
        if let r = rich, let storage = r.textStorage {
            let sel = r.selectedRange()
            guard sel.length > 0, NSMaxRange(sel) <= storage.length else { return nil }
            if sel.location == 0 && sel.length == storage.length { return nil }
            let sub = storage.attributedSubstring(from: sel)
            let md = MarkdownCodec.serialize(RichBridge.blocks(from: sub))
            return md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : md
        } else if let tv = textView {
            let sel = tv.selectedRange()
            let ns = tv.string as NSString
            guard sel.length > 0, NSMaxRange(sel) <= ns.length else { return nil }
            if sel.location == 0 && sel.length == ns.length { return nil }
            let sub = ns.substring(with: sel)
            return sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : sub
        }
        return nil
    }

    private func applyAIReplacement(
        _ markdown: String,
        to target: AITextTarget,
        insertionOnly: Bool = false,
        startVersion: Int,
        conflictTitle: String
    ) {
        let currentSnapshot = (target.richSelection != nil ? richView?.textStorage?.string : textView?.string) ?? ""
        guard editVersion == startVersion, currentSnapshot == target.startSnapshot else {
            alert(conflictTitle, String(localized: "处理期间文档已修改，请重新操作。"))
            return
        }
        let baseURL = fileURL?.deletingLastPathComponent()
        if let sel = target.richSelection, let r = richView, let storage = r.textStorage, NSMaxRange(sel) <= storage.length {
            let writeRange = insertionOnly ? NSRange(location: NSMaxRange(sel), length: 0) : sel
            let formattedText: String
            if insertionOnly {
                let prefix = writeRange.location > 0 && !(storage.string as NSString).substring(to: writeRange.location).hasSuffix("\n") ? "\n" : ""
                formattedText = prefix + markdown
            } else {
                formattedText = markdown
            }
            let rendered = NSMutableAttributedString(attributedString: RichBridge.attributed(markdown: formattedText, baseURL: baseURL))
            if !target.isFullDocument && !insertionOnly, rendered.string.hasSuffix("\n") {
                rendered.deleteCharacters(in: NSRange(location: rendered.length - 1, length: 1))
            }
            r.replace(writeRange, with: rendered, caret: writeRange.location + rendered.length)
            r.refreshTypingAttributes()
            flushPendingEdits()
        } else if let sel = target.sourceSelection, let tv = textView, NSMaxRange(sel) <= (tv.string as NSString).length {
            let writeRange = insertionOnly ? NSRange(location: NSMaxRange(sel), length: 0) : sel
            let output: String
            if insertionOnly {
                let before = (tv.string as NSString).substring(to: writeRange.location)
                let prefix = before.isEmpty ? "" : before.hasSuffix("\n\n") ? "" : before.hasSuffix("\n") ? "\n" : "\n\n"
                output = prefix + markdown + "\n"
            } else {
                output = (target.isFullDocument && !markdown.hasSuffix("\n")) ? markdown + "\n" : markdown
            }
            replace(writeRange, with: output)
        }
    }

    func showWritingTools() {
        guard SiriAIManager.isWritingToolsAvailable else { return }
        flushPendingEdits()
        guard let target = (isRichMode ? richView : (rich ?? textView)) else { return }
        if let window = target.window,
           window.firstResponder !== richView && window.firstResponder !== textView {
            window.makeFirstResponder(target)
        }
        let sender: Any = target.window.flatMap { Self.findToolbarControl(labeled: String(localized: "写作工具"), in: $0) } ?? target
        NSApp.sendAction(NSSelectorFromString("showWritingTools:"), to: target, from: sender)
    }

    func smartFormatMarkdown() {
        guard !isAIFormatting else { return }
        guard #available(macOS 26.0, *), SiriAIManager.isLanguageModelAvailable else {
            alert(String(localized: "智能整理排版不可用"), String(localized: "需要在支持 Apple 智能的 macOS 26 及以上系统中开启该功能。"))
            return
        }
        flushPendingEdits()
        guard let target = captureAITextTarget(requireSelection: false),
              !target.sourceMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let startVersion = editVersion
        isAIFormatting = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isAIFormatting = false }
            do {
                let formatted = try await SiriAIManager.smartFormatMarkdown(target.sourceMarkdown)
                guard !formatted.isEmpty else { return }
                self.applyAIReplacement(
                    formatted,
                    to: target,
                    startVersion: startVersion,
                    conflictTitle: String(localized: "智能整理排版已取消")
                )
            } catch {
                self.alert(String(localized: "智能整理排版失败"), error.localizedDescription)
            }
        }
    }

    func convertSelectionToTable() {
        guard !isAIFormatting else { return }
        guard #available(macOS 26.0, *), SiriAIManager.isLanguageModelAvailable else {
            alert(String(localized: "转换为表格不可用"), String(localized: "需要在支持 Apple 智能的 macOS 26 及以上系统中开启该功能。"))
            return
        }
        flushPendingEdits()
        guard let target = captureAITextTarget(requireSelection: true),
              !target.sourceMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            alert(String(localized: "请先选择要转换为表格的文字"), String(localized: "在文档中选中一段文字后，再选择“转换为表格”。"))
            return
        }
        let startVersion = editVersion
        isAIFormatting = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isAIFormatting = false }
            do {
                let tableMD = try await SiriAIManager.convertToMarkdownTable(target.sourceMarkdown)
                guard !tableMD.isEmpty else {
                    self.alert(String(localized: "未能生成表格"), String(localized: "所选文字中没有可整理为表格的内容。"))
                    return
                }
                self.applyAIReplacement(
                    tableMD,
                    to: target,
                    startVersion: startVersion,
                    conflictTitle: String(localized: "转换为表格已取消")
                )
            } catch {
                self.alert(String(localized: "转换为表格失败"), error.localizedDescription)
            }
        }
    }

    func extractTasksFromDocument() {
        guard !isAIFormatting else { return }
        guard #available(macOS 26.0, *), SiriAIManager.isLanguageModelAvailable else {
            alert(String(localized: "提取待办清单不可用"), String(localized: "需要在支持 Apple 智能的 macOS 26 及以上系统中开启该功能。"))
            return
        }
        flushPendingEdits()
        guard let target = captureAITextTarget(requireSelection: false),
              !target.sourceMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let startVersion = editVersion
        isAIFormatting = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isAIFormatting = false }
            do {
                let tasksMD = try await SiriAIManager.extractTaskList(target.sourceMarkdown)
                guard !tasksMD.isEmpty else {
                    self.alert(String(localized: "未发现待办事项"), String(localized: "当前内容中没有可提取的待办任务。"))
                    return
                }
                self.applyAIReplacement(
                    tasksMD,
                    to: target,
                    insertionOnly: true,
                    startVersion: startVersion,
                    conflictTitle: String(localized: "提取待办清单已取消")
                )
            } catch {
                self.alert(String(localized: "提取待办清单失败"), error.localizedDescription)
            }
        }
    }

    func generateDocumentFrontMatter() {
        guard !isAIFormatting else { return }
        guard #available(macOS 26.0, *), SiriAIManager.isLanguageModelAvailable else {
            alert(String(localized: "生成文档属性不可用"), String(localized: "需要在支持 Apple 智能的 macOS 26 及以上系统中开启该功能。"))
            return
        }
        flushPendingEdits()
        guard let target = captureAITextTarget(requireSelection: false, forceFullDocument: true),
              !target.sourceMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let startVersion = editVersion
        isAIFormatting = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isAIFormatting = false }
            do {
                let yaml = try await SiriAIManager.generateFrontMatter(for: target.sourceMarkdown)
                guard !yaml.isEmpty else { return }
                let updated = SiriAIManager.upsertYAMLFrontMatter(yaml, into: target.sourceMarkdown)
                self.applyAIReplacement(
                    updated,
                    to: target,
                    startVersion: startVersion,
                    conflictTitle: String(localized: "生成文档属性已取消")
                )
            } catch {
                self.alert(String(localized: "生成文档属性失败"), error.localizedDescription)
            }
        }
    }

    func generateDocumentSummary(force: Bool = false) {
        guard #available(macOS 26.0, *), SiriAIManager.isLanguageModelAvailable else {
            summaryError = String(localized: "需要在支持 Apple 智能的 macOS 26 及以上系统中开启该功能。")
            isSummarizing = false
            return
        }
        flushPendingEdits()
        let selected = selectedTextForSummary()
        let isSelection = selected != nil
        let fullText = isRichMode ? (pendingText.isEmpty ? (richMarkdown ?? "") : pendingText) : (textView?.string ?? pendingText)
        let source = selected ?? fullText
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cancelDocumentSummary()
            summaryBullets = []
            summaryIsSelection = false
            summaryError = nil
            lastSummarizedKey = nil
            return
        }
        if !force, let last = lastSummarizedKey, last.isSelection == isSelection, last.text == source, !summaryBullets.isEmpty {
            return
        }

        summaryTask?.cancel()
        summaryToken &+= 1
        let token = summaryToken
        summaryIsSelection = isSelection
        isSummarizing = true
        summaryError = nil

        summaryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.summaryToken == token {
                    self.isSummarizing = false
                    self.summaryTask = nil
                }
            }
            do {
                let bullets = try await SiriAIManager.summarizeBullets(source, isSelection: isSelection)
                guard !Task.isCancelled, self.summaryToken == token else { return }
                self.summaryBullets = bullets
                self.summaryIsSelection = isSelection
                self.lastSummarizedKey = (isSelection, source)
                if bullets.isEmpty {
                    self.summaryError = String(localized: "未能提取到有效摘要要点。")
                }
            } catch is CancellationError {
                // 取消由新任务或 cancelDocumentSummary() 统一接管状态
            } catch {
                guard !Task.isCancelled, self.summaryToken == token else { return }
                self.summaryError = error.localizedDescription
            }
        }
    }

    func cancelDocumentSummary() {
        summaryToken &+= 1
        summaryTask?.cancel()
        summaryTask = nil
        isSummarizing = false
    }

    func askDocumentQuestion(_ rawQuestion: String) {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnsweringQA else { return }
        guard #available(macOS 26.0, *), SiriAIManager.isLanguageModelAvailable else {
            qaMessages.append(DocumentQAItem(
                question: question,
                answer: String(localized: "需要在支持 Apple 智能的 macOS 26 及以上系统中开启该功能。"),
                isLoading: false,
                isError: true
            ))
            return
        }
        flushPendingEdits()
        let document = isRichMode ? (richMarkdown ?? pendingText) : (textView?.string ?? pendingText)
        guard !document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            qaMessages.append(DocumentQAItem(
                question: question,
                answer: String(localized: "当前文档为空，无法回答问题。"),
                isLoading: false,
                isError: true
            ))
            return
        }

        let history = qaMessages
            .filter { !$0.isLoading && !$0.isError && !$0.answer.isEmpty }
            .map { (question: $0.question, answer: $0.answer) }
        let placeholder = DocumentQAItem(question: question, answer: "", isLoading: true, isError: false)
        qaMessages.append(placeholder)
        let targetID = placeholder.id
        isAnsweringQA = true

        qaTask?.cancel()
        qaToken &+= 1
        let token = qaToken
        qaTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.qaToken == token {
                    self.isAnsweringQA = false
                    self.qaTask = nil
                }
            }
            do {
                let answer = try await SiriAIManager.answerQuestion(question, document: document, history: history)
                guard !Task.isCancelled, self.qaToken == token else { return }
                if let idx = self.qaMessages.firstIndex(where: { $0.id == targetID }) {
                    self.qaMessages[idx].answer = answer.isEmpty ? String(localized: "未能生成回答。") : answer
                    self.qaMessages[idx].isLoading = false
                    self.qaMessages[idx].isError = answer.isEmpty
                }
            } catch is CancellationError {
                if self.qaToken == token {
                    self.qaMessages.removeAll { $0.id == targetID && $0.isLoading }
                }
            } catch {
                guard !Task.isCancelled, self.qaToken == token else { return }
                if let idx = self.qaMessages.firstIndex(where: { $0.id == targetID }) {
                    self.qaMessages[idx].answer = error.localizedDescription
                    self.qaMessages[idx].isLoading = false
                    self.qaMessages[idx].isError = true
                }
            }
        }
    }

    func clearDocumentQA() {
        cancelDocumentQA()
        qaMessages.removeAll()
    }

    func cancelDocumentQA() {
        qaToken &+= 1
        qaTask?.cancel()
        qaTask = nil
        isAnsweringQA = false
        qaMessages.removeAll { $0.isLoading }
    }

    func translateDocument(to languageID: String) {
        guard !isTranslatingDocument, SiriAIManager.isDocumentTranslationAvailable else { return }
        flushPendingEdits()
        let source = isRichMode ? (richMarkdown ?? pendingText) : (textView?.string ?? pendingText)
        let segments = MarkdownTranslator.extractSegments(from: source)
        guard !segments.isEmpty else {
            alert(String(localized: "没有可翻译的正文"), String(localized: "当前文档中没有可翻译的自然语言内容。"))
            return
        }
        isTranslatingDocument = true
        documentTranslationRequest = DocumentTranslationRequest(
            targetLanguage: languageID,
            sourceMarkdown: source,
            segments: segments
        )
    }

    func finishDocumentTranslation(_ translatedMarkdown: String) {
        isTranslatingDocument = false
        documentTranslationRequest = nil
        PendingDraftStore.store(translatedMarkdown)
        do {
            try NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
        } catch {
            _ = PendingDraftStore.consume()
            alert(String(localized: "翻译整篇文档失败"), error.localizedDescription)
        }
    }

    func failDocumentTranslation(_ error: Error) {
        isTranslatingDocument = false
        documentTranslationRequest = nil
        if error is CancellationError { return }
        alert(String(localized: "翻译整篇文档失败"), error.localizedDescription)
    }

    func openImagePlayground() {
        #if canImport(ImagePlayground)
        guard #available(macOS 15.2, *),
              SiriAIManager.isImagePlaygroundAvailable,
              let window = (richView ?? textView)?.window,
              let presenter = window.contentViewController,
              let view = window.contentView else { return }
        flushPendingEdits()
        var seed = ""
        if let r = rich, let storage = r.textStorage {
            let sel = r.selectedRange()
            let ns = storage.string as NSString
            if sel.length > 0, NSMaxRange(sel) <= ns.length {
                seed = ns.substring(with: sel)
            }
        } else if let tv = textView {
            let sel = tv.selectedRange()
            let ns = tv.string as NSString
            if sel.length > 0, NSMaxRange(sel) <= ns.length {
                seed = ns.substring(with: sel)
            }
        }
        let concept = String(seed.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        let vc = ImagePlaygroundViewController()
        if !concept.isEmpty {
            vc.concepts = [.text(concept)]
        }
        let proxy = ImagePlaygroundDelegateProxy(
            onCreate: { [weak self] url in
                self?.insertGeneratedImage(from: url, concept: concept)
            },
            onDone: { [weak self] in
                self?.imagePlaygroundDelegate = nil
            }
        )
        imagePlaygroundDelegate = proxy
        vc.delegate = proxy
        let top = view.safeAreaInsets.top
        let anchor = NSRect(x: view.bounds.midX, y: view.isFlipped ? top - 1 : view.bounds.maxY - top, width: 1, height: 1)
        presenter.present(vc, asPopoverRelativeTo: anchor, of: view, preferredEdge: view.isFlipped ? .maxY : .minY, behavior: .semitransient)
        #endif
    }

    func insertGeneratedImage(from tempURL: URL, concept: String) {
        let fm = FileManager.default
        let ext = tempURL.pathExtension.isEmpty ? "png" : tempURL.pathExtension
        let fileName = "image-\(UUID().uuidString.prefix(8)).\(ext)"

        let targetDir: URL
        let markdownPath: String
        if let docURL = fileURL {
            let baseDir = docURL.deletingLastPathComponent()
            let folderName = "\(docURL.deletingPathExtension().lastPathComponent)_images"
            targetDir = baseDir.appendingPathComponent(folderName, isDirectory: true)
            markdownPath = "\(folderName)/\(fileName)"
        } else {
            let pictures = fm.urls(for: .picturesDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
            targetDir = pictures.appendingPathComponent("DropMD", isDirectory: true)
            markdownPath = targetDir.appendingPathComponent(fileName).path
        }

        do {
            try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
            let destURL = targetDir.appendingPathComponent(fileName)
            if fm.fileExists(atPath: destURL.path) { try fm.removeItem(at: destURL) }
            try fm.copyItem(at: tempURL, to: destURL)
        } catch {
            alert(String(localized: "保存生成的图片失败"), error.localizedDescription)
            return
        }

        let alt = DocumentTitleSuggester.sanitizeFileName(concept, maxLength: 30) ?? String(localized: "生成图像")
        if let r = rich {
            r.insertImage(path: markdownPath, alt: alt)
        } else {
            replaceSelection(with: "![\(alt)](\(MarkdownCodec.encodeURL(RichTextView.encodedImagePath(markdownPath))))")
        }
    }
}

#if canImport(ImagePlayground)
@available(macOS 15.2, *)
@MainActor
private final class ImagePlaygroundDelegateProxy: NSObject, ImagePlaygroundViewController.Delegate {
    let onCreate: (URL) -> Void
    let onDone: () -> Void

    init(onCreate: @escaping (URL) -> Void, onDone: @escaping () -> Void) {
        self.onCreate = onCreate
        self.onDone = onDone
    }

    func imagePlaygroundViewController(_ imagePlaygroundViewController: ImagePlaygroundViewController, didCreateImageAt imageURL: URL) {
        imagePlaygroundViewController.dismiss(nil)
        onCreate(imageURL)
        onDone()
    }

    func imagePlaygroundViewControllerDidCancel(_ imagePlaygroundViewController: ImagePlaygroundViewController) {
        imagePlaygroundViewController.dismiss(nil)
        onDone()
    }
}
#endif

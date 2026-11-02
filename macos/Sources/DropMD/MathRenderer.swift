import AppKit
import WebKit

/// 单页中的公式：用预览页面里的 KaTeX 在后台把公式画成图片（不联网）。
/// 图片只用作“形状”，画的时候填上当前文字颜色，浅色 / 深色模式都清楚。
@MainActor
final class MathRenderer: NSObject, WKNavigationDelegate {
    static let shared = MathRenderer()

    struct Result {
        let mask: NSImage      // 白色、带透明度的公式形状
        let descent: CGFloat   // 基线以下的高度（行内公式与文字对齐）
    }

    /// 预览页面（含 KaTeX）；只用 swift run 开发时没有，公式就显示原文
    var pageURL: URL? = Bundle.main.resourceURL?.appendingPathComponent("preview/preview.html")

    private var webView: WKWebView?
    private var window: NSWindow?
    private var ready = false
    private var queue: [(key: String, latex: String, display: Bool, size: CGFloat)] = []
    private var waiting: [String: [(Result?) -> Void]] = [:]
    private var cache: [String: Result] = [:]
    private var busy = false

    func render(_ latex: String, display: Bool, size: CGFloat, completion: @escaping (Result?) -> Void) {
        let key = "\(display ? "D" : "I")\(size)|\(latex)"
        if let r = cache[key] { return completion(r) }
        guard let url = pageURL, FileManager.default.fileExists(atPath: url.path) else { return completion(nil) }
        if waiting[key] != nil { waiting[key]!.append(completion); return }
        waiting[key] = [completion]
        queue.append((key, latex, display, size))
        if webView == nil { load(url) } else { next() }
    }

    private func load(_ url: URL) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1600, height: 800), configuration: config)
        wv.navigationDelegate = self
        // 放在屏幕外的窗口里：不在窗口中的网页不会真正绘制，截不到图
        let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1600, height: 800), styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.isExcludedFromWindowsMenu = true          // 不出现在“窗口”菜单、调度中心里
        w.collectionBehavior = [.transient, .ignoresCycle]
        w.appearance = NSAppearance(named: .aqua)
        w.contentView = wv
        w.orderBack(nil)
        webView = wv
        window = w
        wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        next()
    }

    /// 系统结束了后台网页（如内存紧张）：重新加载，加载完接着画排队的公式
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        webView.reload()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.path == pageURL?.path ? .allow : .cancel)
    }

    private static let script = """
    document.documentElement.style.background = "transparent";
    document.body.style.background = "#fff";
    document.body.innerHTML = "";
    const box = document.createElement("div");
    box.style.cssText = "position:absolute;left:0;top:0;display:inline-block;padding:2px 1px;color:#000;white-space:nowrap;line-height:1.2;font-size:" + size + "px";
    box.innerHTML = katex.renderToString(latex, { displayMode: display, throwOnError: false, output: "html", strict: "ignore" });
    const mark = document.createElement("span");
    mark.style.cssText = "display:inline-block;width:0;height:0;vertical-align:baseline";
    if (display) box.firstChild.style.margin = "0"; else box.appendChild(mark);
    document.body.appendChild(box);
    box.getBoundingClientRect();  // 先排版一次，KaTeX 才开始加载需要的字体
    await document.fonts.ready;   // 字体加载完再量尺寸
    await new Promise(r => setTimeout(r, 30));   // 等页面画好再截图
    const r = box.getBoundingClientRect();
    const base = display ? r.bottom : mark.getBoundingClientRect().top;
    return [r.width, r.height, r.bottom - base];
    """

    private func next() {
        guard ready, !busy, let job = queue.first, let webView else { return }
        busy = true
        queue.removeFirst()
        webView.callAsyncJavaScript(Self.script, arguments: ["latex": job.latex, "display": job.display, "size": job.size],
                                    in: nil, in: .page) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard case .success(let value) = result, let a = value as? [Double], a.count == 3, a[0] > 0, a[1] > 0 else {
                    return self.finish(job.key, nil)
                }
                let config = WKSnapshotConfiguration()
                config.rect = NSRect(x: 0, y: 0, width: ceil(a[0]), height: ceil(a[1]))
                webView.takeSnapshot(with: config) { image, _ in
                    MainActor.assumeIsolated {
                        let mask = image.flatMap(Self.mask)
                        self.finish(job.key, mask.map { Result(mask: $0, descent: CGFloat(a[2])) })
                    }
                }
            }
        }
    }

    private func finish(_ key: String, _ result: Result?) {
        if let result { cache[key] = result }
        let done = waiting.removeValue(forKey: key) ?? []
        busy = false
        for c in done { c(result) }
        next()
    }

    /// 白底黑字的截图 → 白色、按黑色深浅透明的形状
    private static func mask(_ image: NSImage) -> NSImage? {
        guard let tiff = image.tiffRepresentation, let input = CIImage(data: tiff),
              let inverted = CIFilter(name: "CIColorInvert", parameters: [kCIInputImageKey: input])?.outputImage,
              let alpha = CIFilter(name: "CIMaskToAlpha", parameters: [kCIInputImageKey: inverted])?.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: alpha)
        let out = NSImage(size: image.size)
        out.addRepresentation(rep)
        return out
    }
}

/// 公式在单页中的显示：渲染好之前显示原文（紫色），之后显示公式
final class MathAttachmentCell: NSTextAttachmentCell {
    let latex: String
    let display: Bool
    private let placeholder: NSAttributedString
    private var result: MathRenderer.Result?
    private weak var layoutManager: NSLayoutManager?

    init(source: String, display: Bool, font: NSFont) {
        latex = Self.latex(from: source, display: display)
        self.display = display
        placeholder = NSAttributedString(string: source.replacingOccurrences(of: "\n", with: " "),
                                         attributes: [.font: font, .foregroundColor: NSColor.systemPurple])
        super.init(textCell: "")
        let size = font.pointSize * (display ? 1.15 : 1.05)
        MainActor.assumeIsolated {
            MathRenderer.shared.render(latex, display: display, size: size) { [weak self] r in
                guard let self, let r else { return }
                self.result = r
                self.refresh()
            }
        }
    }

    required init(coder: NSCoder) { fatalError("不支持") }

    /// $…$、\(…\)、$$…$$、\[…\] → 公式本身
    static func latex(from source: String, display: Bool) -> String {
        var s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in display ? [("$$", "$$"), ("\\[", "\\]")] : [("$", "$"), ("\\(", "\\)")]
        where s.hasPrefix(open) && s.hasSuffix(close) && s.count >= open.count + close.count {
            s = String(s.dropFirst(open.count).dropLast(close.count))
            break
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    override func cellSize() -> NSSize {
        result?.mask.size ?? placeholder.size()
    }

    /// 排版时记下排版器：屏幕外（还没画过）的公式渲染好后也能更新尺寸
    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        layoutManager = textContainer.layoutManager
        return super.cellFrame(for: textContainer, proposedLineFragment: lineFrag, glyphPosition: position, characterIndex: charIndex)
    }

    override func cellBaselineOffset() -> NSPoint {
        if let result { return NSPoint(x: 0, y: -result.descent) }
        return NSPoint(x: 0, y: (placeholder.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.descender ?? 0)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let mask = result?.mask else {
            placeholder.draw(at: cellFrame.origin)
            return
        }
        // 用当前文字颜色填充公式的形状
        let tinted = NSImage(size: mask.size, flipped: false) { rect in
            NSColor.labelColor.setFill()
            rect.fill()
            mask.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        tinted.draw(in: cellFrame)
    }

    /// 渲染好后重新排版这个公式所在的位置
    private func refresh() {
        guard let lm = layoutManager, let storage = lm.textStorage, let attachment else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard (value as? NSTextAttachment) === attachment else { return }
            lm.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            lm.invalidateDisplay(forCharacterRange: range)
            stop.pointee = true
        }
    }
}

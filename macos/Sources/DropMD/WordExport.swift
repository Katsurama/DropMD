import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 将 Markdown 文档导出为 Word（.docx）。
/// 优先使用随程序打包的 Pandoc，同时修饰生成的 OOXML 样式表（表格网格边框、代码块浅灰底色与自动换行）；
/// 开发或单测环境中若无 Pandoc，也支持由 MarkdownCodec 直接生成标准 OOXML（.docx）。
enum WordExport {
    enum ExportError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .failed(let message): return message
            }
        }
    }

    /// 导出 Markdown 为 .docx 文件；base 为文档所在的文件夹（用于解析相对路径的本机图片）
    static func export(markdown: String, to destination: URL, base: URL?) throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("dropmd-docx-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let tempDocx = tempDir.appendingPathComponent("out.docx")
        if let pandoc = pandocExecutable() {
            try exportWithPandoc(pandoc, markdown: markdown, to: tempDocx, base: base, tempDir: tempDir)
            try polishPandocStyles(at: tempDocx, tempDir: tempDir)
        } else {
            try exportBuiltIn(markdown: markdown, to: tempDocx, base: base, tempDir: tempDir)
        }

        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: tempDocx)
        } else {
            try fm.moveItem(at: tempDocx, to: destination)
        }
    }

    // MARK: - Pandoc 导出路径

    /// 查找随程序打包或本机安装的 Pandoc
    static func pandocExecutable() -> URL? {
        if let engine = Engine.executableURL {
            let dir = engine.deletingLastPathComponent()
            for rel in ["_internal/pandoc/pandoc", "pandoc/pandoc"] {
                let p = dir.appendingPathComponent(rel)
                if FileManager.default.isExecutableFile(atPath: p.path) { return p }
            }
        }
        if let res = Bundle.main.resourceURL {
            for rel in ["engine/_internal/pandoc/pandoc", "engine/pandoc/pandoc", "pandoc/pandoc"] {
                let p = res.appendingPathComponent(rel)
                if FileManager.default.isExecutableFile(atPath: p.path) { return p }
            }
        }
        let repoPandoc = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("packaging/pandoc/pandoc")
        if FileManager.default.isExecutableFile(atPath: repoPandoc.path) { return repoPandoc }
        for path in ["/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc"] where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// 文件开头的 YAML 信息（--- … ---）转成 yaml 代码块：导出时不报错，也不当成 Word 居中封面或表格
    private static func convertFrontMatter(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { ["---", "..."].contains($0.trimmingCharacters(in: .whitespaces)) }) else {
            return normalized
        }
        let body = lines[1..<end].joined(separator: "\n")
        let rest = lines[(end + 1)...].joined(separator: "\n")
        return "```yaml\n" + (body.isEmpty ? "" : body + "\n") + "```\n" + rest
    }

    /// 供 Pandoc 使用的 Lua 过滤器：
    /// 1. <u> / <sub> / <sup> / <kbd> / <mark> / <br> 转为原生 Word 样式；
    /// 2. 去掉 <details> / <summary> 标签外壳，保留标题和内部内容；
    /// 3. 提示框标题（Note / Tip 等）替换为当前界面语言的粗体标题；
    /// 4. 拦截 http / https 网络图片，绝不联网请求；本机路径的 %20 解码以便 Pandoc 读取文件；
    /// 5. 表格设为占满页面宽度。
    private static let pandocLuaFilter = #"""
    local tags = {u = true, sub = true, sup = true, kbd = true, mark = true}
    local callouts = {
      note = os.getenv("DROPMD_CALLOUT_NOTE"),
      tip = os.getenv("DROPMD_CALLOUT_TIP"),
      important = os.getenv("DROPMD_CALLOUT_IMPORTANT"),
      warning = os.getenv("DROPMD_CALLOUT_WARNING"),
      caution = os.getenv("DROPMD_CALLOUT_CAUTION"),
    }

    local function url_decode(s)
      return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
    end

    function Inlines(inlines)
      local stack = {}
      local cur = {}
      local function wrap(tag, content)
        if tag == "u" then return pandoc.Underline(content)
        elseif tag == "sub" then return pandoc.Subscript(content)
        elseif tag == "sup" then return pandoc.Superscript(content)
        elseif tag == "kbd" then return pandoc.Code(pandoc.utils.stringify(content))
        elseif tag == "mark" then return pandoc.Span(content, {class = "mark"})
        end
        return pandoc.Span(content)
      end
      for _, el in ipairs(inlines) do
        if el.t == "RawInline" and el.format == "html" then
          local open = el.text:lower():match("^<(%a+)>$")
          local close = el.text:lower():match("^</(%a+)>$")
          if open and tags[open] then
            table.insert(stack, {tag = open, list = cur})
            cur = {}
          elseif close and tags[close] and #stack > 0 and stack[#stack].tag == close then
            local top = table.remove(stack)
            local node = wrap(close, cur)
            cur = top.list
            table.insert(cur, node)
          elseif el.text:lower():match("^<br%s*/?>$") then
            table.insert(cur, pandoc.LineBreak())
          else
            table.insert(cur, el)
          end
        else
          table.insert(cur, el)
        end
      end
      while #stack > 0 do
        local top = table.remove(stack)
        for _, x in ipairs(cur) do table.insert(top.list, x) end
        cur = top.list
      end
      return cur
    end

    function RawBlock(el)
      if el.format == "html" then
        local t = el.text:lower()
        if t:match("^%s*<details") or t:match("^%s*</details>") or t:match("^%s*<summary") or t:match("^%s*</summary>") then
          return {}
        end
      end
    end

    function Div(el)
      if el.classes:includes("title") and #el.content == 1 and el.content[1].t == "Para" then
        local key = pandoc.utils.stringify(el.content[1]):lower()
        if callouts[key] and callouts[key] ~= "" then
          el.content[1] = pandoc.Para({pandoc.Strong({pandoc.Str(callouts[key])})})
          return el
        end
      end
    end

    function Image(el)
      local lower = el.src:lower()
      if lower:match("^https?://") or lower:match("^//") then
        local alt = pandoc.utils.stringify(el.caption)
        local label = os.getenv("DROPMD_BLOCKED_IMAGE") or "Web image not loaded"
        local colon = os.getenv("DROPMD_COLON") or ": "
        return pandoc.Emph({pandoc.Str("[" .. label .. (alt ~= "" and (colon .. alt) or "") .. "]")})
      end
      if not lower:match("^data:") then
        local base = os.getenv("DROPMD_BASE_DIR") or ""
        local decoded = url_decode(el.src)
        local candidate = (decoded:sub(1, 1) == "/" or base == "") and decoded or (base .. "/" .. decoded)
        local f = io.open(candidate, "rb")
        if f then
          f:close()
          el.src = candidate
        end
      end
      return el
    end

    function Table(el)
      local cols = #el.colspecs
      if cols > 0 then
        local has_width = false
        for i = 1, cols do
          if el.colspecs[i][2] ~= nil then has_width = true; break end
        end
        if not has_width then
          local w = 1.0 / cols
          for i = 1, cols do
            el.colspecs[i] = {el.colspecs[i][1], w}
          end
        end
      end
      return el
    end
    """#

    private static func exportWithPandoc(_ pandoc: URL, markdown: String, to output: URL, base: URL?, tempDir: URL) throws {
        let inputURL = tempDir.appendingPathComponent("input.md")
        let filterURL = tempDir.appendingPathComponent("docx_filter.lua")
        // 通过 MarkdownCodec 规范化一轮：将无空行紧贴的表格、下划线标题、缩进代码等统一为标准语法
        let normalized = MarkdownCodec.serialize(MarkdownCodec.parse(markdown), preserving: markdown)
        try Data(convertFrontMatter(normalized).utf8).write(to: inputURL)
        try Data(pandocLuaFilter.utf8).write(to: filterURL)

        let fromFormat = [
            "markdown",
            "+alerts",
            "+task_lists",
            "+strikeout",
            "+mark",
            "+autolink_bare_uris",
            "+emoji",
            "+tex_math_dollars",
            "+tex_math_single_backslash",
            "+tex_math_double_backslash",
            "+lists_without_preceding_blankline",
            "+hard_line_breaks",
            "-yaml_metadata_block",
            "-implicit_figures",
            "-subscript",
            "-superscript",
            "-simple_tables",
            "-multiline_tables",
            "-grid_tables",
            "-smart",
        ].joined()

        var args = [
            inputURL.path,
            "--from=\(fromFormat)",
            "--to=docx",
            "--lua-filter=\(filterURL.path)",
            "-o", output.path,
        ]
        if let base {
            args.append("--resource-path=\(base.path)")
        }

        let proc = Process()
        proc.executableURL = pandoc
        proc.arguments = args
        if let base { proc.currentDirectoryURL = base }
        var env = ProcessInfo.processInfo.environment
        for c in MDCallout.allCases { env["DROPMD_CALLOUT_\(c.rawValue)"] = c.title }
        env["DROPMD_BLOCKED_IMAGE"] = String(localized: "网络图片未加载（隐私保护）")
        env["DROPMD_COLON"] = String(localized: "：")
        if let base { env["DROPMD_BASE_DIR"] = base.path }
        proc.environment = env

        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe
        try proc.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0, FileManager.default.fileExists(atPath: output.path) else {
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ExportError.failed(msg.isEmpty ? "Pandoc (\(proc.terminationStatus))" : msg)
        }
    }

    /// 修饰 Pandoc 生成的 word/styles.xml：
    /// 1. 给 Table 样式加上浅灰四周边框与内边距、表头浅灰底色；
    /// 2. 给 SourceCode 代码块加上浅灰底色、细边框与自动折行（避免长代码行超出纸张）。
    private static func polishPandocStyles(at docxURL: URL, tempDir: URL) throws {
        let unpackDir = tempDir.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpackDir, withIntermediateDirectories: true)
        guard runCommand("/usr/bin/ditto", ["-x", "-k", docxURL.path, unpackDir.path]) else { return }

        let stylesURL = unpackDir.appendingPathComponent("word/styles.xml")
        guard var xml = try? String(contentsOf: stylesURL, encoding: .utf8) else { return }

        // 1. 表格加上网格边框与单元格上下内边距，表头加浅灰底色
        let oldTablePr = """
        <w:tblPr>
              <w:tblInd w:type="dxa" w:w="0" />
              <w:tblCellMar>
                <w:top w:type="dxa" w:w="0" />
                <w:left w:type="dxa" w:w="108" />
                <w:bottom w:type="dxa" w:w="0" />
                <w:right w:type="dxa" w:w="108" />
              </w:tblCellMar>
            </w:tblPr>
        """
        let newTablePr = """
        <w:tblPr>
              <w:tblInd w:type="dxa" w:w="0" />
              <w:tblBorders>
                <w:top w:val="single" w:sz="4" w:space="0" w:color="D0D7DE" />
                <w:left w:val="single" w:sz="4" w:space="0" w:color="D0D7DE" />
                <w:bottom w:val="single" w:sz="4" w:space="0" w:color="D0D7DE" />
                <w:right w:val="single" w:sz="4" w:space="0" w:color="D0D7DE" />
                <w:insideH w:val="single" w:sz="4" w:space="0" w:color="D0D7DE" />
                <w:insideV w:val="single" w:sz="4" w:space="0" w:color="D0D7DE" />
              </w:tblBorders>
              <w:tblCellMar>
                <w:top w:type="dxa" w:w="80" />
                <w:left w:type="dxa" w:w="120" />
                <w:bottom w:type="dxa" w:w="80" />
                <w:right w:type="dxa" w:w="120" />
              </w:tblCellMar>
            </w:tblPr>
        """
        xml = xml.replacingOccurrences(of: oldTablePr, with: newTablePr)
        xml = xml.replacingOccurrences(
            of: "<w:vAlign w:val=\"bottom\" />",
            with: "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F6F8FA\" /><w:vAlign w:val=\"center\" />"
        )

        // 2. 代码块段落：开启自动换行，加上浅灰背景与细边框
        let oldSourceCode = "<w:pPr><w:wordWrap w:val=\"off\" /></w:pPr>"
        let newSourceCode = """
        <w:pPr>\
        <w:pBdr>\
        <w:top w:val="single" w:sz="4" w:space="6" w:color="E1E4E8" />\
        <w:left w:val="single" w:sz="4" w:space="8" w:color="E1E4E8" />\
        <w:bottom w:val="single" w:sz="4" w:space="6" w:color="E1E4E8" />\
        <w:right w:val="single" w:sz="4" w:space="8" w:color="E1E4E8" />\
        </w:pBdr>\
        <w:shd w:val="clear" w:color="auto" w:fill="F6F8FA" />\
        <w:spacing w:before="120" w:after="120" />\
        </w:pPr>
        """
        xml = xml.replacingOccurrences(of: oldSourceCode, with: newSourceCode)

        try Data(xml.utf8).write(to: stylesURL)
        let repacked = tempDir.appendingPathComponent("repacked.docx")
        if runCommand("/usr/bin/ditto", ["-c", "-k", "--norsrc", unpackDir.path, repacked.path]) {
            _ = try? FileManager.default.replaceItemAt(docxURL, withItemAt: repacked)
        }
    }

    // MARK: - 内置纯 Swift OOXML 兜底生成器（无 Pandoc 环境时使用）

    private struct Rel {
        let id: String
        let type: String
        let target: String
        let external: Bool
    }

    private static func exportBuiltIn(markdown: String, to output: URL, base: URL?, tempDir: URL) throws {
        let pkg = tempDir.appendingPathComponent("pkg", isDirectory: true)
        let wordDir = pkg.appendingPathComponent("word", isDirectory: true)
        let relsDir = pkg.appendingPathComponent("_rels", isDirectory: true)
        let wordRelsDir = wordDir.appendingPathComponent("_rels", isDirectory: true)
        let mediaDir = wordDir.appendingPathComponent("media", isDirectory: true)
        let fm = FileManager.default
        for d in [pkg, wordDir, relsDir, wordRelsDir] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }

        let blocks = MarkdownCodec.parse(markdown)
        var rels: [Rel] = [
            Rel(id: "rId1", type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles", target: "styles.xml", external: false),
            Rel(id: "rId2", type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering", target: "numbering.xml", external: false),
        ]
        var nextRel = 3
        var nextPicId = 1
        var imageExts: Set<String> = []
        var bodyXML = ""

        func addHyperlink(_ url: String) -> String {
            let id = "rId\(nextRel)"
            nextRel += 1
            rels.append(Rel(id: id, type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink", target: url, external: true))
            return id
        }

        func addImage(_ rawPath: String, alt: String) -> String? {
            guard let img = resolveLocalImage(rawPath, base: base) else { return nil }
            try? fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
            let id = "rId\(nextRel)"
            nextRel += 1
            let picId = nextPicId
            nextPicId += 1
            let name = "image\(picId).\(img.ext)"
            try? img.data.write(to: mediaDir.appendingPathComponent(name))
            imageExts.insert(img.ext)
            rels.append(Rel(id: id, type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", target: "media/\(name)", external: false))
            // Word 页面正文宽约 15cm（5,400,000 EMU），图片按比例缩放到不超过页面宽度
            let maxWidthPts: Double = 440
            let scale = min(1.0, maxWidthPts / max(img.width, 1))
            let cx = Int((img.width * scale * 12700).rounded())
            let cy = Int((img.height * scale * 12700).rounded())
            let descr = xmlEscape(alt)
            return """
            <w:r><w:drawing><wp:inline><wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(picId)" name="Picture \(picId)" descr="\(descr)"/>\
            <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
            <pic:pic><pic:nvPicPr><pic:cNvPr id="\(picId)" name="\(xmlEscape(name))" descr="\(descr)"/><pic:cNvPicPr/></pic:nvPicPr>\
            <pic:blipFill><a:blip r:embed="\(id)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
            <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
            </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
            """
        }

        func renderRuns(_ runs: [MDRun], forceBold: Bool = false) -> String {
            var out = ""
            for r in runs {
                if let src = r.image {
                    let drawing = addImage(src, alt: r.text) ?? "<w:r><w:t xml:space=\"preserve\">[\(xmlEscape(r.text.isEmpty ? src : r.text))]</w:t></w:r>"
                    if let link = r.link, !link.isEmpty {
                        out += "<w:hyperlink r:id=\"\(addHyperlink(link))\">\(drawing)</w:hyperlink>"
                    } else {
                        out += drawing
                    }
                    continue
                }
                var rPr = ""
                if r.code || r.kbd { rPr += "<w:rStyle w:val=\"VerbatimChar\"/>" }
                if r.link != nil { rPr += "<w:rStyle w:val=\"Hyperlink\"/>" }
                if r.bold || forceBold { rPr += "<w:b/><w:bCs/>" }
                if r.italic { rPr += "<w:i/><w:iCs/>" }
                if r.underline || r.link != nil { rPr += "<w:u w:val=\"single\"/>" }
                if r.strike { rPr += "<w:strike/>" }
                if r.highlight { rPr += "<w:highlight w:val=\"yellow\"/>" }
                if r.sup { rPr += "<w:vertAlign w:val=\"superscript\"/>" }
                if r.sub { rPr += "<w:vertAlign w:val=\"subscript\"/>" }
                let pr = rPr.isEmpty ? "" : "<w:rPr>\(rPr)</w:rPr>"
                let lines = r.text.replacingOccurrences(of: "\u{2028}", with: "\n").components(separatedBy: "\n")
                var inner = ""
                for (idx, part) in lines.enumerated() {
                    if idx > 0 { inner += "<w:br/>" }
                    inner += "<w:t xml:space=\"preserve\">\(xmlEscape(part))</w:t>"
                }
                let runXML = "<w:r>\(pr)\(inner)</w:r>"
                if let link = r.link, !link.isEmpty {
                    out += "<w:hyperlink r:id=\"\(addHyperlink(link))\">\(runXML)</w:hyperlink>"
                } else {
                    out += runXML
                }
            }
            return out
        }

        func renderBlocks(_ list: [MDBlock]) {
            for block in list {
                switch block {
                case .line(let line):
                    switch line.kind {
                    case .body:
                        bodyXML += "<w:p><w:pPr><w:pStyle w:val=\"BodyText\"/></w:pPr>\(renderRuns(line.runs))</w:p>"
                    case .heading(let level):
                        let lv = min(max(level, 1), 6)
                        bodyXML += "<w:p><w:pPr><w:pStyle w:val=\"Heading\(lv)\"/></w:pPr>\(renderRuns(line.runs))</w:p>"
                    case .quote:
                        var runs = line.runs
                        if runs.count == 1, runs[0].literal, let c = MDCallout(header: runs[0].text) {
                            runs = [MDRun(text: c.title, bold: true)]
                        }
                        bodyXML += "<w:p><w:pPr><w:pStyle w:val=\"BlockText\"/></w:pPr>\(renderRuns(runs))</w:p>"
                    case .bullet(let depth):
                        let ilvl = min(max(depth, 0), 8)
                        bodyXML += "<w:p><w:pPr><w:pStyle w:val=\"Compact\"/><w:numPr><w:ilvl w:val=\"\(ilvl)\"/><w:numId w:val=\"1\"/></w:numPr></w:pPr>\(renderRuns(line.runs))</w:p>"
                    case .ordered(let depth):
                        let ilvl = min(max(depth, 0), 8)
                        bodyXML += "<w:p><w:pPr><w:pStyle w:val=\"Compact\"/><w:numPr><w:ilvl w:val=\"\(ilvl)\"/><w:numId w:val=\"2\"/></w:numPr></w:pPr>\(renderRuns(line.runs))</w:p>"
                    case .task(let depth, let done):
                        let ilvl = min(max(depth, 0), 8)
                        let box = MDRun(text: (done ? "☑ " : "☐ "))
                        bodyXML += "<w:p><w:pPr><w:pStyle w:val=\"Compact\"/><w:numPr><w:ilvl w:val=\"\(ilvl)\"/><w:numId w:val=\"1\"/></w:numPr></w:pPr>\(renderRuns([box] + line.runs))</w:p>"
                    }
                case .code(_, let lines, _):
                    let content = lines.enumerated().map { idx, l in
                        (idx > 0 ? "<w:br/>" : "") + "<w:t xml:space=\"preserve\">\(xmlEscape(l))</w:t>"
                    }.joined()
                    bodyXML += "<w:p><w:pPr><w:pStyle w:val=\"SourceCode\"/></w:pPr><w:r><w:rPr><w:rStyle w:val=\"VerbatimChar\"/></w:rPr>\(content)</w:r></w:p>"
                case .table(let rows, let align):
                    let cols = max(1, rows.map(\.count).max() ?? 1)
                    let gridCols = String(repeating: "<w:gridCol w:w=\"\(9000 / cols)\"/>", count: cols)
                    var tbl = "<w:tbl><w:tblPr><w:tblStyle w:val=\"Table\"/><w:tblW w:type=\"pct\" w:w=\"5000\"/></w:tblPr><w:tblGrid>\(gridCols)</w:tblGrid>"
                    for (rIdx, row) in rows.enumerated() {
                        tbl += "<w:tr>" + (rIdx == 0 ? "<w:trPr><w:tblHeader w:val=\"on\"/></w:trPr>" : "")
                        for cIdx in 0..<cols {
                            let marker = cIdx < align.count ? align[cIdx] : "---"
                            let jc = marker == ":-:" ? "<w:jc w:val=\"center\"/>" : marker == "--:" ? "<w:jc w:val=\"right\"/>" : "<w:jc w:val=\"left\"/>"
                            let shd = rIdx == 0 ? "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F6F8FA\"/>" : ""
                            let runs = cIdx < row.count ? row[cIdx] : []
                            tbl += "<w:tc><w:tcPr>\(shd)</w:tcPr><w:p><w:pPr><w:pStyle w:val=\"Compact\"/>\(jc)</w:pPr>\(renderRuns(runs, forceBold: rIdx == 0))</w:p></w:tc>"
                        }
                        tbl += "</w:tr>"
                    }
                    tbl += "</w:tbl>"
                    bodyXML += tbl
                case .rule:
                    bodyXML += "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"D0D7DE\"/></w:pBdr></w:pPr></w:p>"
                case .details(let summary, let inner, _):
                    if !summary.isEmpty {
                        bodyXML += "<w:p><w:pPr><w:pStyle w:val=\"BodyText\"/></w:pPr>\(renderRuns([MDRun(text: summary, bold: true)]))</w:p>"
                    }
                    renderBlocks(inner)
                case .raw(let text):
                    let content = text.components(separatedBy: "\n").enumerated().map { idx, l in
                        (idx > 0 ? "<w:br/>" : "") + "<w:t xml:space=\"preserve\">\(xmlEscape(l))</w:t>"
                    }.joined()
                    bodyXML += "<w:p><w:pPr><w:pStyle w:val=\"SourceCode\"/></w:pPr><w:r><w:rPr><w:rStyle w:val=\"VerbatimChar\"/></w:rPr>\(content)</w:r></w:p>"
                }
            }
        }

        renderBlocks(blocks)

        let docXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
        <w:body>\(bodyXML)<w:sectPr/></w:body>
        </w:document>
        """
        try Data(docXML.utf8).write(to: wordDir.appendingPathComponent("document.xml"))
        try Data(builtInStylesXML.utf8).write(to: wordDir.appendingPathComponent("styles.xml"))
        try Data(builtInNumberingXML.utf8).write(to: wordDir.appendingPathComponent("numbering.xml"))

        let relItems = rels.map { r in
            "<Relationship Id=\"\(r.id)\" Type=\"\(r.type)\" Target=\"\(xmlEscape(r.target))\"\(r.external ? " TargetMode=\"External\"" : "")/>"
        }.joined()
        let docRelsXML = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(relItems)</Relationships>"
        try Data(docRelsXML.utf8).write(to: wordRelsDir.appendingPathComponent("document.xml.rels"))

        let rootRelsXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """
        try Data(rootRelsXML.utf8).write(to: relsDir.appendingPathComponent(".rels"))

        let imgDefaults = imageExts.sorted().map { ext in
            let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "image/\(ext)"
            return "<Default Extension=\"\(ext)\" ContentType=\"\(mime)\"/>"
        }.joined()
        let contentTypesXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="xml" ContentType="application/xml"/>
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        \(imgDefaults)
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
        </Types>
        """
        try Data(contentTypesXML.utf8).write(to: pkg.appendingPathComponent("[Content_Types].xml"))

        guard runCommand("/usr/bin/ditto", ["-c", "-k", "--norsrc", pkg.path, output.path]) else {
            throw ExportError.failed("Unable to package Word document.")
        }
    }

    private static func resolveLocalImage(_ rawPath: String, base: URL?) -> (data: Data, ext: String, width: Double, height: Double)? {
        let lower = rawPath.lowercased()
        if lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("//") { return nil }
        var data: Data?
        var ext = "png"
        if lower.hasPrefix("data:image/"), let comma = rawPath.firstIndex(of: ",") {
            let meta = rawPath[..<comma].lowercased()
            if meta.contains("jpeg") || meta.contains("jpg") { ext = "jpg" }
            else if meta.contains("gif") { ext = "gif" }
            data = Data(base64Encoded: String(rawPath[rawPath.index(after: comma)...]), options: .ignoreUnknownCharacters)
        } else {
            let decoded = rawPath.removingPercentEncoding ?? rawPath
            let url = decoded.hasPrefix("/") ? URL(fileURLWithPath: decoded) : base.map { URL(fileURLWithPath: decoded, relativeTo: $0) }
            if let url, let d = try? Data(contentsOf: url) {
                data = d
                let e = url.pathExtension.lowercased()
                if !e.isEmpty { ext = e == "jpeg" ? "jpg" : e }
            }
        }
        guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double,
              let h = props[kCGImagePropertyPixelHeight] as? Double, w > 0, h > 0 else { return nil }
        return (data, ext, w, h)
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func runCommand(_ launchPath: String, _ arguments: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static let builtInStylesXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
      <w:style w:type="paragraph" w:styleId="BodyText"><w:name w:val="Body Text"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:before="120" w:after="120"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Compact"><w:name w:val="Compact"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:before="40" w:after="40"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:before="320" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="40"/></w:rPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:before="240" w:after="100"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:before="200" w:after="80"/><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:sz w:val="28"/></w:rPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading4"><w:name w:val="heading 4"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:before="160" w:after="60"/><w:outlineLvl w:val="3"/></w:pPr><w:rPr><w:b/><w:sz w:val="24"/></w:rPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading5"><w:name w:val="heading 5"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:before="120" w:after="60"/><w:outlineLvl w:val="4"/></w:pPr><w:rPr><w:b/><w:sz w:val="22"/></w:rPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading6"><w:name w:val="heading 6"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:before="120" w:after="60"/><w:outlineLvl w:val="5"/></w:pPr><w:rPr><w:b/><w:color w:val="595959"/><w:sz w:val="22"/></w:rPr></w:style>
      <w:style w:type="paragraph" w:styleId="BlockText"><w:name w:val="Block Text"/><w:basedOn w:val="BodyText"/><w:pPr><w:ind w:left="480" w:right="480"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:customStyle="1" w:styleId="SourceCode"><w:name w:val="Source Code"/><w:basedOn w:val="Normal"/><w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F6F8FA"/><w:spacing w:before="120" w:after="120"/></w:pPr></w:style>
      <w:style w:type="character" w:customStyle="1" w:styleId="VerbatimChar"><w:name w:val="Verbatim Char"/><w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/><w:sz w:val="21"/></w:rPr></w:style>
      <w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:rPr><w:color w:val="0969DA"/><w:u w:val="single"/></w:rPr></w:style>
      <w:style w:type="table" w:default="1" w:styleId="Table"><w:name w:val="Table"/><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:space="0" w:color="D0D7DE"/><w:left w:val="single" w:sz="4" w:space="0" w:color="D0D7DE"/><w:bottom w:val="single" w:sz="4" w:space="0" w:color="D0D7DE"/><w:right w:val="single" w:sz="4" w:space="0" w:color="D0D7DE"/><w:insideH w:val="single" w:sz="4" w:space="0" w:color="D0D7DE"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="D0D7DE"/></w:tblBorders></w:tblPr></w:style>
    </w:styles>
    """

    private static let builtInNumberingXML: String = {
        var bulletLvls = ""
        var decLvls = ""
        for i in 0...8 {
            let left = (i + 1) * 720
            bulletLvls += "<w:lvl w:ilvl=\"\(i)\"><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"•\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(left)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
            decLvls += "<w:lvl w:ilvl=\"\(i)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:lvlText w:val=\"%\(i + 1).\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(left)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="multilevel"/>\(bulletLvls)</w:abstractNum>
          <w:abstractNum w:abstractNumId="2"><w:multiLevelType w:val="multilevel"/>\(decLvls)</w:abstractNum>
          <w:num w:numId="1"><w:abstractNumId w:val="1"/></w:num>
          <w:num w:numId="2"><w:abstractNumId w:val="2"/></w:num>
        </w:numbering>
        """
    }()
}

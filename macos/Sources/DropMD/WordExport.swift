import Foundation

/// 将 Markdown 文档导出为 Word（.docx）。
/// 使用随程序打包的 Pandoc，同时修饰生成的 OOXML 样式表（表格网格边框、代码块浅灰底色与自动换行）。
enum WordExport {
    enum ExportError: LocalizedError {
        case pandocNotFound
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .pandocNotFound:
                return String(localized: "找不到 Word 导出组件（Pandoc），程序可能不完整，请重新下载安装。")
            case .failed(let message):
                return message
            }
        }
    }

    /// 导出 Markdown 为 .docx 文件；base 为文档所在的文件夹（用于解析相对路径的本机图片）
    static func export(markdown: String, to destination: URL, base: URL?) throws {
        guard let pandoc = pandocExecutable() else { throw ExportError.pandocNotFound }
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("dropmd-docx-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let tempDocx = tempDir.appendingPathComponent("out.docx")
        try exportWithPandoc(pandoc, markdown: markdown, to: tempDocx, base: base, tempDir: tempDir)
        try polishPandocStyles(at: tempDocx, tempDir: tempDir)

        // 原子写到目标所在卷，避免跨卷 replaceItemAt 失败与悬空符号链接报错
        try Data(contentsOf: tempDocx).write(to: destination, options: .atomic)
    }

    // MARK: - Pandoc 导出路径

    /// 查找随程序打包的 Pandoc（仅调试构建回退到仓库内的二进制）
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
        #if DEBUG
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("packaging/pandoc/pandoc"),
            URL(fileURLWithPath: "/Applications/DropMD.app/Contents/Resources/engine/_internal/pandoc/pandoc"),
            URL(fileURLWithPath: "/Applications/DropMD.app/Contents/Resources/engine/pandoc/pandoc"),
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p.path) { return p }
        #endif
        return nil
    }

    /// 预处理块：
    /// 1. 文件开头的 YAML 信息（--- … ---）转为 yaml 代码块，避免 Pandoc 报错或当成居中封面/表格；
    /// 2. 展开折叠块（保留粗体标题与内部内容），避免 Pandoc 把 <details>/<summary> 当作原始 HTML 块丢弃。
    private static func prepareBlocks(_ blocks: [MDBlock]) -> [MDBlock] {
        var prepared = blocks
        if case .raw(let text)? = prepared.first {
            let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
               let end = lines.dropFirst().firstIndex(where: { ["---", "..."].contains($0.trimmingCharacters(in: .whitespaces)) }) {
                var replacement: [MDBlock] = [.code(lang: "yaml", lines: Array(lines[1..<end]))]
                let rest = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .newlines)
                if !rest.isEmpty { replacement.append(.raw(rest)) }
                prepared.replaceSubrange(0..<1, with: replacement)
            }
        }
        return flattenDetails(prepared)
    }

    private static func flattenDetails(_ blocks: [MDBlock]) -> [MDBlock] {
        blocks.flatMap { block -> [MDBlock] in
            guard case .details(let summary, let body, _) = block else { return [block] }
            var out: [MDBlock] = []
            if !summary.isEmpty {
                out.append(.line(MDLine(kind: .body, runs: [MDRun(text: summary, bold: true)])))
            }
            out.append(contentsOf: flattenDetails(body))
            return out
        }
    }

    /// 供 Pandoc 使用的 Lua 过滤器：
    /// 1. <u> / <sub> / <sup> / <kbd> / <mark> / <b> / <i> / <s> / <del> / <br> 转为原生 Word 样式；
    /// 2. 兜底展开未被 MarkdownCodec 拆开的 <details> / <summary> 原始 HTML 块；
    /// 3. 提示框标题（Note / Tip 等）替换为当前界面语言的粗体标题；
    /// 4. 只放行 data:image/ 与本机存在的文件（写入 mediabag 避免二次解码），拦截其余一切 URI 方案；
    /// 5. 表格设为占满页面宽度。
    private static let pandocLuaFilter = #"""
    local tags = {
      u = true, sub = true, sup = true, kbd = true, mark = true,
      b = true, strong = true, i = true, em = true, s = true, del = true,
    }
    local callouts = {
      note = os.getenv("DROPMD_CALLOUT_NOTE"),
      tip = os.getenv("DROPMD_CALLOUT_TIP"),
      important = os.getenv("DROPMD_CALLOUT_IMPORTANT"),
      warning = os.getenv("DROPMD_CALLOUT_WARNING"),
      caution = os.getenv("DROPMD_CALLOUT_CAUTION"),
    }
    local img_count = 0

    local function url_decode(s)
      return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
    end

    local function trim(s)
      return (s:gsub("^%s+", ""):gsub("%s+$", ""))
    end

    local function blocked_placeholder(el)
      local alt = pandoc.utils.stringify(el.caption)
      local label = os.getenv("DROPMD_BLOCKED_IMAGE") or "Online picture not loaded"
      local colon = os.getenv("DROPMD_COLON") or ": "
      return pandoc.Emph({pandoc.Str("[" .. label .. (alt ~= "" and (colon .. alt) or "") .. "]")})
    end

    local function missing_placeholder(el)
      local alt = pandoc.utils.stringify(el.caption)
      local label = os.getenv("DROPMD_IMAGE_LABEL") or "Image"
      return pandoc.Emph({pandoc.Str("[" .. (alt ~= "" and alt or label) .. "]")})
    end

    local function strip_tag(s, name)
      local out = s
      while true do
        local l = out:lower()
        local a, b = l:find("</?" .. name .. "%f[%s/>][^>]*>")
        if not a then break end
        out = out:sub(1, a - 1) .. out:sub(b + 1)
      end
      return out
    end

    local function handle_inlines(inlines)
      local stack = {}
      local cur = {}
      local function wrap(tag, content)
        if tag == "u" then return pandoc.Underline(content)
        elseif tag == "sub" then return pandoc.Subscript(content)
        elseif tag == "sup" then return pandoc.Superscript(content)
        elseif tag == "kbd" then return pandoc.Code(pandoc.utils.stringify(content))
        elseif tag == "mark" then return pandoc.Span(content, {class = "mark"})
        elseif tag == "b" or tag == "strong" then return pandoc.Strong(content)
        elseif tag == "i" or tag == "em" then return pandoc.Emph(content)
        elseif tag == "s" or tag == "del" then return pandoc.Strikeout(content)
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

    -- HTML 写的 <img>：Word 不认 HTML，转成普通图片，交给下面的 handle_image 嵌入（在线图片换成提示）
    local function html_attr(tag, name)
      local p = "%s" .. name .. "%s*=%s*"
      return tag:match(p .. '"([^"]*)"') or tag:match(p .. "'([^']*)'") or tag:match(p .. "([^%s>\"']+)")
    end

    local function html_images(text)
      local out = {}
      text = text:gsub("<!%-%-.-%-%->", "")   -- 注释里的 <img> 不算
      for tag in text:gmatch("<[Ii][Mm][Gg]%s[^>]*>") do
        tag = tag:gsub("%s*/>$", " >")   -- <img src=a.png/>：/ 不算地址的一部分
        local src = html_attr(tag, "[Ss][Rr][Cc]")
        if src and src ~= "" then
          local alt = html_attr(tag, "[Aa][Ll][Tt]") or ""
          local kv = {}
          local w, h = html_attr(tag, "[Ww][Ii][Dd][Tt][Hh]"), html_attr(tag, "[Hh][Ee][Ii][Gg][Hh][Tt]")
          -- 纯数字按像素；带单位（%、px、cm 等）原样交给 Pandoc
          local function size(v) v = v:lower() return v:match("^[%d.]+$") and (v .. "px") or v end
          if w then table.insert(kv, {"width", size(w)}) end
          if h then table.insert(kv, {"height", size(h)}) end
          table.insert(out, pandoc.Image({pandoc.Str(alt)}, src, "", pandoc.Attr("", {}, kv)))
        end
      end
      return out
    end

    local function handle_raw_inline(el)
      if el.format ~= "html" or not el.text:lower():match("^<img%s") then return nil end
      local imgs = html_images(el.text)
      if #imgs > 0 then return imgs end
    end

    local function handle_raw_block(el)
      if el.format ~= "html" then return nil end
      local lower = el.text:lower()
      if not (lower:match("^%s*</?details[%s/>]") or lower:match("^%s*</?summary[%s/>]")) then
        local imgs = html_images(el.text)
        if #imgs > 0 then return pandoc.Para(imgs) end
        return nil
      end
      local out = {}
      local rest = el.text
      local s1, s2 = rest:lower():find("<summary%f[%s>][^>]*>")
      if s1 then
        local e1, e2 = rest:lower():find("</summary%s*>", s2 + 1)
        if e1 then
          local sum_html = rest:sub(s2 + 1, e1 - 1)
          local sum_text = trim(pandoc.utils.stringify(pandoc.read(sum_html, "html")))
          if sum_text ~= "" then
            table.insert(out, pandoc.Para({pandoc.Strong({pandoc.Str(sum_text)})}))
          end
          rest = rest:sub(1, s1 - 1) .. "\n" .. rest:sub(e2 + 1)
        end
      end
      rest = trim(strip_tag(strip_tag(rest, "details"), "summary"))
      if rest ~= "" then
        -- 用和整篇相同的写法规则读（高亮、待办、不把 ~ 当下标）
        local doc = pandoc.read(rest, os.getenv("DROPMD_PANDOC_FROM") or "markdown-yaml_metadata_block-pandoc_title_block")
        for _, b in ipairs(doc.blocks) do
          table.insert(out, b)
        end
      end
      return out
    end

    local function handle_div(el)
      if el.classes:includes("title") and #el.content == 1 and el.content[1].t == "Para" then
        local key = pandoc.utils.stringify(el.content[1]):lower()
        if callouts[key] and callouts[key] ~= "" then
          el.content[1] = pandoc.Para({pandoc.Strong({pandoc.Str(callouts[key])})})
          return el
        end
      end
    end

    local function handle_image(el)
      local src = trim(el.src or "")
      local lower = src:lower()
      if lower:match("^data:image/") then
        el.src = src
        return el
      end
      -- Pandoc 会把尖括号地址里的前导空格编成 %20，解码后一并拦截协议头，避免 fetchItem 联网或读系统路径
      local decoded = url_decode(src)
      local decoded_lower = trim(decoded):lower()
      if lower:match("^//") or lower:match("^[%a][%w+.-]*:")
         or decoded_lower:match("^//") or decoded_lower:match("^[%a][%w+.-]*:") then
        return blocked_placeholder(el)
      end
      if decoded == "" or decoded:find("%z") then
        return missing_placeholder(el)
      end
      local allowed_img_exts = {
        png = true, jpg = true, jpeg = true, gif = true,
        webp = true, bmp = true, tif = true, tiff = true,
        svg = true, heic = true, avif = true
      }
      local ext = decoded:match("%.([%w]+)$")
      local lower_ext = ext and ext:lower() or ""
      if not allowed_img_exts[lower_ext] then
        return missing_placeholder(el)
      end
      local base = os.getenv("DROPMD_BASE_DIR") or ""
      local is_abs = decoded:sub(1, 1) == "/"
      if not is_abs and base == "" then
        return missing_placeholder(el)
      end
      local candidate = is_abs and decoded or (base .. "/" .. decoded)
      local f = io.open(candidate, "rb")
      if not f then
        return missing_placeholder(el)
      end
      -- macOS 上 io.open 可以打开目录，seek/read 会返回 nil；先限制体积再写入 mediabag，避免读入超大文件或二次 URL 解码
      local max_bytes = 50 * 1024 * 1024
      local size = f:seek("end")
      if not size or size <= 0 or size > max_bytes then
        f:close()
        return missing_placeholder(el)
      end
      f:seek("set", 0)
      local bytes = f:read(max_bytes + 1)
      f:close()
      if not bytes or #bytes == 0 or #bytes > max_bytes then
        return missing_placeholder(el)
      end
      img_count = img_count + 1
      local name = "dropmd_img_" .. img_count .. "." .. lower_ext
      pandoc.mediabag.insert(name, nil, bytes)
      el.src = name
      return el
    end

    local function handle_table(el)
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

    return {
      { RawBlock = handle_raw_block, RawInline = handle_raw_inline },
      { Inlines = handle_inlines, Div = handle_div, Image = handle_image, Table = handle_table },
    }
    """#

    private static func exportWithPandoc(_ pandoc: URL, markdown: String, to output: URL, base: URL?, tempDir: URL) throws {
        let inputURL = tempDir.appendingPathComponent("input.md")
        let filterURL = tempDir.appendingPathComponent("docx_filter.lua")
        let dataDir = tempDir.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        // 不传 preserving，避免直接返回原文导致紧贴段落的表格缺少空行；同时转换 Front Matter 与展开折叠块
        let normalized = MarkdownCodec.serialize(prepareBlocks(MarkdownCodec.parse(markdown)))
        try Data(normalized.utf8).write(to: inputURL)
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
            "-pandoc_title_block",
            "-implicit_figures",
            "-subscript",
            "-superscript",
            "-simple_tables",
            "-multiline_tables",
            "-grid_tables",
            "-smart",
        ].joined()

        let args = [
            inputURL.path,
            "--from=\(fromFormat)",
            "--to=docx",
            "--data-dir=\(dataDir.path)",
            "--lua-filter=\(filterURL.path)",
            "-o", output.path,
        ]

        let proc = Process()
        proc.executableURL = pandoc
        proc.arguments = args
        // 工作目录固定为临时目录，避免未保存文档中的相对路径解析到宿主工作目录
        proc.currentDirectoryURL = tempDir
        var env = ProcessInfo.processInfo.environment
        env["DROPMD_PANDOC_FROM"] = fromFormat
        for c in MDCallout.allCases { env["DROPMD_CALLOUT_\(c.rawValue)"] = c.title }
        env["DROPMD_BLOCKED_IMAGE"] = String(localized: "在线图片未加载（隐私保护）")
        env["DROPMD_COLON"] = String(localized: "：")
        env["DROPMD_IMAGE_LABEL"] = String(localized: "图片")
        if let base {
            env["DROPMD_BASE_DIR"] = base.path
        } else {
            env.removeValue(forKey: "DROPMD_BASE_DIR")
        }
        proc.environment = env

        final class TimeoutBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            func markTimedOut() { lock.lock(); value = true; lock.unlock() }
            var isTimedOut: Bool { lock.lock(); defer { lock.unlock() }; return value }
        }
        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe
        try proc.run()
        let timeoutBox = TimeoutBox()
        let timer = DispatchWorkItem {
            guard proc.isRunning else { return }
            timeoutBox.markTimedOut()
            proc.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120, execute: timer)
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        timer.cancel()

        guard proc.terminationStatus == 0, FileManager.default.fileExists(atPath: output.path) else {
            if timeoutBox.isTimedOut {
                throw ExportError.failed(String(localized: "导出 Word 超时，请稍后重试。"))
            }
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ExportError.failed(msg.isEmpty ? "Pandoc (\(proc.terminationStatus))" : msg)
        }
    }

    /// 修饰 Pandoc 生成的 word/styles.xml：
    /// 1. 统一正文与各级标题的字体、色彩、粗细与行距（去除 Pandoc 默认偏旧的深海蓝与斜体标题）；
    /// 2. 给 Table 样式加上浅灰四周边框与内边距、表头浅灰底色；
    /// 3. 给 SourceCode 代码块、BlockText 引用块、VerbatimChar 行内代码加上现代浅灰边框或底色与自动折行。
    private static func polishPandocStyles(at docxURL: URL, tempDir: URL) throws {
        let unpackDir = tempDir.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpackDir, withIntermediateDirectories: true)
        guard Engine.runCommand("/usr/bin/ditto", ["-x", "-k", docxURL.path, unpackDir.path]) else { return }

        let stylesURL = unpackDir.appendingPathComponent("word/styles.xml")
        guard var xml = try? String(contentsOf: stylesURL, encoding: .utf8) else { return }

        // 0. 现代排版：正文字号 11pt、1.35 倍行距；各级标题改为深炭黑粗体，去除 H4/H6 默认斜体
        xml = xml.replacingOccurrences(
            of: "<w:pPr>\n        <w:spacing w:after=\"200\" />\n      </w:pPr>",
            with: "<w:pPr>\n        <w:spacing w:after=\"160\" w:line=\"324\" w:lineRule=\"auto\" />\n      </w:pPr>"
        )
        xml = xml.replacingOccurrences(
            of: "<w:spacing w:after=\"180\" w:before=\"180\" />",
            with: "<w:spacing w:after=\"140\" w:before=\"80\" w:line=\"324\" w:lineRule=\"auto\" />"
        )
        xml = xml.replacingOccurrences(
            of: "<w:color w:themeColor=\"accent1\" w:themeShade=\"BF\" w:val=\"0F4761\" />",
            with: "<w:b /><w:bCs /><w:color w:val=\"1D1D1F\" />"
        )
        xml = xml.replacingOccurrences(
            of: "<w:i />\n      <w:iCs />\n      <w:b /><w:bCs /><w:color w:val=\"1D1D1F\" />",
            with: "<w:b /><w:bCs /><w:color w:val=\"1D1D1F\" />"
        )
        xml = xml.replacingOccurrences(
            of: "<w:i />\n      <w:iCs />\n      <w:color w:themeColor=\"text1\" w:themeTint=\"A6\" w:val=\"595959\" />",
            with: "<w:b /><w:bCs /><w:color w:val=\"57606A\" />"
        )

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
                <w:top w:type="dxa" w:w="100" />
                <w:left w:type="dxa" w:w="140" />
                <w:bottom w:type="dxa" w:w="100" />
                <w:right w:type="dxa" w:w="140" />
              </w:tblCellMar>
            </w:tblPr>
        """
        xml = xml.replacingOccurrences(of: oldTablePr, with: newTablePr)
        xml = xml.replacingOccurrences(
            of: "<w:vAlign w:val=\"bottom\" />",
            with: "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F6F8FA\" /><w:vAlign w:val=\"center\" />"
        )

        // 2. 引用块（BlockText）与行内代码（VerbatimChar）
        let oldBlockText = """
            <w:pPr>
              <w:spacing w:after="100" w:before="100" />
              <w:ind w:firstLine="0" w:left="480" w:right="480" />
            </w:pPr>
        """
        let newBlockText = """
            <w:pPr>
              <w:pBdr>
                <w:left w:val="single" w:sz="18" w:space="12" w:color="D0D7DE" />
              </w:pBdr>
              <w:spacing w:after="120" w:before="120" w:line="312" w:lineRule="auto" />
              <w:ind w:firstLine="0" w:left="240" w:right="240" />
            </w:pPr>
            <w:rPr>
              <w:color w:val="57606A" />
            </w:rPr>
        """
        xml = xml.replacingOccurrences(of: oldBlockText, with: newBlockText)
        xml = xml.replacingOccurrences(
            of: "<w:rFonts w:ascii=\"Consolas\" w:hAnsi=\"Consolas\" />\n      <w:sz w:val=\"22\" />",
            with: "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\" w:cs=\"Menlo\" />\n      <w:sz w:val=\"21\" />\n      <w:szCs w:val=\"21\" />\n      <w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F6F8FA\" />"
        )

        // 3. 代码块段落：开启自动换行，加上浅灰背景与细边框
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
        <w:spacing w:before="120" w:after="120" w:line="276" w:lineRule="auto" />\
        </w:pPr>
        """
        xml = xml.replacingOccurrences(of: oldSourceCode, with: newSourceCode)

        try Data(xml.utf8).write(to: stylesURL)
        let repacked = tempDir.appendingPathComponent("repacked.docx")
        if Engine.runCommand("/usr/bin/ditto", ["-c", "-k", "--norsrc", unpackDir.path, repacked.path]) {
            _ = try? FileManager.default.replaceItemAt(docxURL, withItemAt: repacked)
        }
    }
}

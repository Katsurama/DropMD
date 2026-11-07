// DropMD 预览：Markdown（markdown-it）+ 数学公式（KaTeX）。
// 由 Swift 通过 evaluateJavaScript 调用 window.DropMD 的方法；本页面不进行任何网络访问。
(function () {
  "use strict";

  // ---------------------------------------------------------------- 数学公式
  // 行内：$...$、\(...\)；块级：$$...$$、\[...\]
  function mathPlugin(md, output) {
    function renderMath(src, display) {
      try {
        return katex.renderToString(src, { displayMode: display, throwOnError: false, output: output, strict: "ignore" });
      } catch (e) {
        return '<span class="math-error">' + md.utils.escapeHtml(src) + "</span>";
      }
    }

    function isWS(c) { return c === 0x20 || c === 0x09 || c === 0x0a; }

    md.inline.ruler.before("escape", "math_inline", function (state, silent) {   // 要在转义之前，否则 \( 先被当成转义的括号
      const s = state.src, pos = state.pos;
      let open, close;
      if (s.charCodeAt(pos) === 0x24 /* $ */) {
        if (s.charCodeAt(pos + 1) === 0x24) return false; // $$ 交给块级或保持原样
        if (isWS(s.charCodeAt(pos + 1))) return false;
        open = "$"; close = "$";
      } else if (s.startsWith("\\(", pos)) {
        open = "\\("; close = "\\)";
      } else {
        return false;
      }
      let end = pos + open.length;
      while ((end = s.indexOf(close, end)) !== -1) {
        if (s.charCodeAt(end - 1) === 0x5c /* \ */ && close === "$") { end += 1; continue; }
        break;
      }
      if (end === -1) return false;
      const content = s.slice(pos + open.length, end);
      if (!content.trim()) return false;
      if (close === "$") {
        if (isWS(s.charCodeAt(end - 1))) return false;
        const after = s.charCodeAt(end + 1);
        if (after >= 0x30 && after <= 0x39) return false; // 像 $5 和 $10 这样的金额
      }
      if (!silent) {
        const t = state.push("math_inline", "math", 0);
        t.content = content;
      }
      state.pos = end + close.length;
      return true;
    });

    md.block.ruler.after("blockquote", "math_block", function (state, startLine, endLine, silent) {
      let pos = state.bMarks[startLine] + state.tShift[startLine];
      let max = state.eMarks[startLine];
      const first = state.src.slice(pos, max);
      let open, close;
      if (first.startsWith("$$")) { open = "$$"; close = "$$"; }
      else if (first.startsWith("\\[")) { open = "\\["; close = "\\]"; }
      else return false;
      if (silent) return true;

      let content = "", line = startLine, found = false;
      let rest = first.slice(open.length);
      // 单行：$$ x $$
      const oneLine = rest.indexOf(close);
      if (oneLine !== -1 && rest.trim().length > 0) {
        if (rest.slice(oneLine + close.length).trim()) return false;   // 后面还有文字：不是公式块，否则这些字会丢
        content = rest.slice(0, oneLine);
        found = true;
      } else {
        content = rest ? rest + "\n" : "";
        for (line = startLine + 1; line < endLine; line++) {
          pos = state.bMarks[line] + state.tShift[line];
          max = state.eMarks[line];
          const text = state.src.slice(pos, max);
          const idx = text.indexOf(close);
          if (idx !== -1) {
            if (text.slice(idx + close.length).trim()) return false;
            content += text.slice(0, idx); found = true; break;
          }
          content += text + "\n";
        }
      }
      if (!found) return false;
      const t = state.push("math_block", "math", 0);
      t.block = true;
      t.content = content;
      t.map = [startLine, line + 1];
      state.line = line + 1;
      return true;
    });

    md.renderer.rules.math_inline = function (tokens, idx) { return renderMath(tokens[idx].content, false); };
    md.renderer.rules.math_block = function (tokens, idx) {
      const t = tokens[idx];
      const attr = t.map ? ' data-line="' + t.map[0] + '"' : "";
      return '<div class="math-block"' + attr + ">" + renderMath(t.content, true) + "</div>\n";
    };
  }

  // ---------------------------------------------------------------- 任务列表 - [ ] / - [x]
  function taskListPlugin(md) {
    md.core.ruler.after("inline", "task_list", function (state) {
      const tokens = state.tokens;
      for (let i = 2; i < tokens.length; i++) {
        const t = tokens[i];
        if (t.type !== "inline" || tokens[i - 1].type !== "paragraph_open" || tokens[i - 2].type !== "list_item_open") continue;
        const m = /^\[([ xX])\]\s+/.exec(t.content);
        if (!m || !t.children.length || t.children[0].type !== "text") continue;
        t.children[0].content = t.children[0].content.replace(/^\[([ xX])\]\s+/, "");
        const box = new state.Token("html_inline", "", 0);
        box.content = '<input type="checkbox" disabled' + (m[1] !== " " ? " checked" : "") + "> ";
        t.children.unshift(box);
        tokens[i - 2].attrJoin("class", "task-list-item");
        for (let j = i - 3; j >= 0; j--) {
          if (tokens[j].type === "bullet_list_open" || tokens[j].type === "ordered_list_open") {
            if (tokens[j].level === tokens[i - 2].level - 1) { tokens[j].attrJoin("class", "contains-task-list"); break; }
          }
        }
      }
    });
  }

  // ---------------------------------------------------------------- 提示框 > [!NOTE]（GitHub 写法）
  // 界面文字：默认中文，App 每次渲染时传入界面语言的文字（render 的 ui 参数）
  const ui = { NOTE: "注意", TIP: "提示", IMPORTANT: "重要", WARNING: "警告", CAUTION: "小心",
               blockedImage: "网络图片未加载（隐私保护）", colon: "：" };
  function calloutPlugin(md) {
    md.core.ruler.after("inline", "callout", function (state) {
      const tokens = state.tokens;
      for (let i = 0; i + 2 < tokens.length; i++) {
        if (tokens[i].type !== "blockquote_open" || tokens[i + 1].type !== "paragraph_open") continue;
        const t = tokens[i + 2];
        const m = /^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\][ \t]*(\n|$)/i.exec(t.content);
        if (!m) continue;
        const type = m[1].toUpperCase();
        // 去掉开头的 [!NOTE]（可能被拆成几个文字片段）和其后的换行
        let rest = m[1].length + 3;
        while (rest > 0 && t.children.length) {
          const c = t.children[0];
          if (c.type !== "text") break;
          if (c.content.length <= rest) { rest -= c.content.length; t.children.shift(); }
          else { c.content = c.content.slice(rest); rest = 0; }
        }
        while (t.children.length && /^(softbreak|hardbreak)$/.test(t.children[0].type)) t.children.shift();
        const title = new state.Token("html_inline", "", 0);
        title.content = '<span class="callout-title">' + ui[type] + "</span>";
        t.children.unshift(title);
        tokens[i].attrJoin("class", "callout callout-" + type.toLowerCase());
      }
    });
  }

  // ---------------------------------------------------------------- 行号映射（用于同步滚动）
  function lineMapPlugin(md) {
    const blocks = ["paragraph_open", "heading_open", "blockquote_open", "bullet_list_open", "ordered_list_open",
      "table_open", "hr", "code_block", "fence", "list_item_open", "html_block"];
    md.core.ruler.push("line_map", function (state) {
      for (const t of state.tokens) {
        if (t.map && blocks.indexOf(t.type) !== -1 && t.level === 0) t.attrSet("data-line", String(t.map[0]));
      }
    });
    // fence/code_block/html_block 默认渲染不输出属性，这里补上
    const fence = md.renderer.rules.fence;
    md.renderer.rules.fence = function (tokens, idx, options, env, self) {
      const html = fence(tokens, idx, options, env, self);
      const line = tokens[idx].attrGet("data-line");
      return line === null ? html : html.replace(/^<pre/, '<pre data-line="' + line + '"');
    };
  }

  // ---------------------------------------------------------------- 网络图片：为保护隐私不加载
  function blockRemoteImages(md) {
    const image = md.renderer.rules.image;
    md.renderer.rules.image = function (tokens, idx, options, env, self) {
      const src = tokens[idx].attrGet("src") || "";
      if (/^(https?:)?\/\//i.test(src)) {
        const alt = md.utils.escapeHtml(tokens[idx].content || "");
        return '<span class="blocked-image" title="' + md.utils.escapeHtml(src) + '">' + md.utils.escapeHtml(ui.blockedImage) +
          (alt ? md.utils.escapeHtml(ui.colon) + alt : "") + "</span>";
      }
      return image(tokens, idx, options, env, self);
    };
  }

  // ---------------------------------------------------------------- 中文粗体
  // 标准规则按英文“词旁有空格”判断，**“重点”**内容、**结论（重要）**以及 这种 AI 常写的中文粗体会失效。
  // 标记外侧是中日韩文字时当作空格看；其余与 markdown-it 原来的 scanDelims 相同。
  function cjkEmphasisPlugin(md) {
    const u = md.utils;
    function isCJK(c) {
      return (c >= 0x2e80 && c <= 0x9fff) || (c >= 0xac00 && c <= 0xd7af) || (c >= 0xf900 && c <= 0xfaff) ||
        (c >= 0xff00 && c <= 0xffef) || (c >= 0x20000 && c <= 0x3ffff);
    }
    function isPunct(c) { return u.isMdAsciiPunct(c) || u.isPunctCharCode(c); }
    md.inline.State.prototype.scanDelims = function (start, canSplitWord) {
      const src = this.src, max = this.posMax, marker = src.charCodeAt(start);
      let last = 0x20;
      if (start > 0) {
        last = src.charCodeAt(start - 1);
        if (last >= 0xdc00 && last <= 0xdfff && start > 1) last = src.codePointAt(start - 2);
      }
      let pos = start;
      while (pos < max && src.charCodeAt(pos) === marker) pos++;
      const next = pos < max ? src.codePointAt(pos) : 0x20;
      const lastP = isPunct(last), nextP = isPunct(next);
      const lastWS = u.isWhiteSpace(last), nextWS = u.isWhiteSpace(next);
      const left = !nextWS && (!nextP || lastWS || isCJK(last) || lastP);
      const right = !lastWS && (!lastP || nextWS || isCJK(next) || nextP);
      return {
        can_open: left && (canSplitWord || !right || lastP),
        can_close: right && (canSplitWord || !left || nextP),
        length: pos - start,
      };
    };
  }

  function makeRenderer(mathOutput, blockRemote) {
    const md = window.markdownit({ html: true, linkify: true, typographer: false });
    // 开源插件：==高亮==（markdown-it-mark）、脚注 [^1]（markdown-it-footnote）
    if (window.markdownitMark) md.use(window.markdownitMark);
    if (window.markdownitFootnote) md.use(window.markdownitFootnote);
    md.use(function (m) { mathPlugin(m, mathOutput); });
    md.use(cjkEmphasisPlugin);
    md.use(taskListPlugin);
    md.use(calloutPlugin);
    md.use(lineMapPlugin);
    if (blockRemote) md.use(blockRemoteImages);
    return md;
  }

  const previewMD = makeRenderer("htmlAndMathml", true);
  // 导出 HTML 用 MathML，无需字体文件，浏览器可直接显示；网络图片保留（是否加载由打开它的浏览器决定）
  const exportMD = makeRenderer("mathml", false);

  // 文件开头的 YAML 信息（--- … ---，Obsidian、Hugo 等用）：显示为代码块，不当成分隔线和标题。
  // 只换掉开头、结尾两行，行数不变，同步滚动不受影响
  function frontMatter(text) {
    const m = /^---[ \t]*\n([\s\S]*?\n)?(?:---|\.\.\.)[ \t]*(\n|$)/.exec(text);
    return m ? "```yaml\n" + (m[1] || "") + "```" + m[2] + text.slice(m[0].length) : text;
  }

  function setBase(baseHref) {
    let base = document.querySelector("base");
    if (!baseHref) { if (base) base.remove(); return; }
    if (!base) { base = document.createElement("base"); document.head.prepend(base); }
    base.href = baseHref;
  }

  window.DropMD = {
    /** 渲染 Markdown。baseHref 为文档所在文件夹的 file:// 地址（以 / 结尾），用于相对路径图片；lang 为文档语言；
        uiText 为界面语言的文字（键同 ui） */
    render: function (text, baseHref, lang, uiText) {
      setBase(baseHref);
      if (uiText) Object.assign(ui, uiText);
      // 文档语言决定汉字字形，见 preview.css
      if (lang) document.documentElement.lang = lang;
      document.getElementById("content").innerHTML = previewMD.render(frontMatter(text || ""));
      return true;
    },

    /** 滚动到与源码第 line 行（从 0 开始）对应的位置 */
    scrollToLine: function (line) {
      const els = document.querySelectorAll("[data-line]");
      let before = null, after = null;
      for (const el of els) {
        const l = parseInt(el.getAttribute("data-line"), 10);
        if (l <= line) before = { el: el, line: l };
        else { after = { el: el, line: l }; break; }
      }
      if (!before) { window.scrollTo(0, 0); return; }
      const top = before.el.getBoundingClientRect().top + window.scrollY;
      let y = top;
      if (after && after.line > before.line) {
        const nextTop = after.el.getBoundingClientRect().top + window.scrollY;
        y = top + (nextTop - top) * (line - before.line) / (after.line - before.line);
      }
      window.scrollTo(0, Math.max(0, y - 24));
    },

    /** 导出为独立 HTML 文件的正文 */
    exportBody: function (text) {
      return exportMD.render(frontMatter(text || ""));
    }
  };
})();

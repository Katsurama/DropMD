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

    md.inline.ruler.after("escape", "math_inline", function (state, silent) {
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
      const oneLine = rest.lastIndexOf(close);
      if (oneLine !== -1 && rest.trim().length > 0) {
        content = rest.slice(0, oneLine);
        found = true;
      } else {
        content = rest ? rest + "\n" : "";
        for (line = startLine + 1; line < endLine; line++) {
          pos = state.bMarks[line] + state.tShift[line];
          max = state.eMarks[line];
          const text = state.src.slice(pos, max);
          const idx = text.indexOf(close);
          if (idx !== -1) { content += text.slice(0, idx); found = true; break; }
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
  const calloutTitles = { NOTE: "注意", TIP: "提示", IMPORTANT: "重要", WARNING: "警告", CAUTION: "小心" };
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
        title.content = '<span class="callout-title">' + calloutTitles[type] + "</span>";
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
        return '<span class="blocked-image" title="' + md.utils.escapeHtml(src) + '">网络图片未加载（隐私保护）' +
          (alt ? "：" + alt : "") + "</span>";
      }
      return image(tokens, idx, options, env, self);
    };
  }

  function makeRenderer(mathOutput) {
    const md = window.markdownit({ html: true, linkify: true, typographer: false });
    // 开源插件：==高亮==（markdown-it-mark）、脚注 [^1]（markdown-it-footnote）
    if (window.markdownitMark) md.use(window.markdownitMark);
    if (window.markdownitFootnote) md.use(window.markdownitFootnote);
    md.use(function (m) { mathPlugin(m, mathOutput); });
    md.use(taskListPlugin);
    md.use(calloutPlugin);
    md.use(lineMapPlugin);
    md.use(blockRemoteImages);
    return md;
  }

  const previewMD = makeRenderer("htmlAndMathml");
  const exportMD = makeRenderer("mathml"); // 导出 HTML 用 MathML，无需字体文件，浏览器可直接显示

  function setBase(baseHref) {
    let base = document.querySelector("base");
    if (!baseHref) { if (base) base.remove(); return; }
    if (!base) { base = document.createElement("base"); document.head.prepend(base); }
    base.href = baseHref;
  }

  window.DropMD = {
    /** 渲染 Markdown。baseHref 为文档所在文件夹的 file:// 地址（以 / 结尾），用于相对路径图片；lang 为文档语言 */
    render: function (text, baseHref, lang) {
      setBase(baseHref);
      // 文档语言决定汉字字形，见 preview.css
      if (lang) document.documentElement.lang = lang;
      document.getElementById("content").innerHTML = previewMD.render(text || "");
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
      return exportMD.render(text || "");
    }
  };
})();

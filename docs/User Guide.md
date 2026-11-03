# DropMD User Guide

DropMD is a **Markdown editor** for the Mac. It can also convert Word, Excel, PowerPoint, HTML, PDF and other files to Markdown. Everything happens on your own Mac; no files are ever uploaded.

The interface is built natively with Swift / SwiftUI and uses the Liquid Glass design on macOS 26 and later.

---

## 1. Installing

You don't need to install Python or type any commands.

### Requirements

- A Mac with Apple silicon (M1 / M2 / M3 / M4 …)
- macOS 14 or later (the Liquid Glass look needs macOS 26 or later)

### Steps

1. Double-click `DropMD-macOS-AppleSilicon.dmg`.
2. In the window that opens, drag the **DropMD** icon onto the “Applications” folder, as the arrow shows.
3. The first time you open it, macOS may say it “can't verify the developer”, because DropMD isn't signed with a paid Apple developer certificate. To open it anyway:
   - Open System Settings → Privacy & Security, find the message about DropMD near the bottom and click “Open Anyway”;
   - or, on older macOS versions, Control-click DropMD.app in Finder and choose “Open”.
   You only need to do this once.

---

## 2. The editor

Create or open a Markdown file from the File menu (New / Open), or drag a .md file onto the DropMD icon in the Dock. The first time you open DropMD, it asks whether to make itself the default app for Markdown files; then double-clicking a .md file in Finder opens it in DropMD. You can change this later in DropMD → Settings… (⌘,). Without that, right-click a .md file in Finder and choose Open With → DropMD.

The “Page / Split” buttons at the left of the toolbar switch between two views (or press ⌘1 / ⌘2, or use the View menu):

- **Page** (default, ⌘1): edit the formatted document directly, like in Pages or Word. **You don't need to know Markdown.** What you see is the final result, and it is saved as a standard Markdown file.
- **Split** (⌘2): the Markdown source on the left and the formatted preview on the right. Useful if you know Markdown, or to see how math formulas look.

You can switch at any time; the content stays in sync. The Format panel on the right (the Format button at the right of the toolbar, or ⌥⌘I) shows the paragraph and text style at the cursor; click to change it. Tables, images, links, collapsible sections and more are in the middle of the toolbar; every command is also in the Format and Insert menus.

### Using Page view

- **Paragraph styles**: in the Format panel, set a paragraph to Body, Heading 1–6, Quote or Code Block (Format → Code Block lets you pick a programming language, including mermaid diagrams). Shortcuts: ⌥⌘1–⌥⌘6 for headings, ⌥⌘0 for body text.
- **Text styles**: Bold (⌘B), Italic (⌘I), Underline (⌘U), Strikethrough (⇧⌘X), **Highlight** (⇧⌘H), Inline Code (⌥⌘C), Superscript (⌃⌘=), Subscript (⌃⌘-) and Keyboard Key. Select text and click a button; click again to remove the style. With nothing selected, the style applies to what you type next.
- **Lists**: bulleted, numbered and **checklists** (click the box to tick it). Press Tab in a list to indent and ⇧Tab to outdent; press Return on an empty item to end the list.
- **Insert** (toolbar, Format panel or the Insert menu):
  - **Link** (⌘K), **Image** (choose an image on your Mac), **Table** (Tab in the last cell adds a row; Return moves to the next cell) and **Divider**;
  - **Collapsible Section** (⇧⌘D): an area that can be clicked open and closed. Write the title after ▸ and the content in the area with the bar below it. Click the ▸ / ▾ before the title to close or open it (this only changes the view, not the file; like a browser, sections start closed when a file is opened). Press Return on the title to go into the content; press Return on an empty line of the content to leave the section. It opens and closes when you export to HTML or view the file on GitHub;
  - **Callout**: Note, Tip, Important, Warning and Caution. The first line shows the callout's name; write the content below it. In the Split preview, on GitHub and in Obsidian it appears as a colored box;
  - **Footnote** (⌥⌘F): inserts a number like [^1] at the cursor and puts the note at the end of the document;
  - **Today's Date** and **Emoji & Symbols** (the system emoji picker);
  - **Line Break (Same Paragraph)** (⇧↩): a new line within the same paragraph, saved as `<br>`;
  - **Inline Formula** (⌥⌘M) and **Formula Block** (⇧⌥⌘M): written in LaTeX, for example `E=mc^2`. Page view shows them as math too; double-click a formula to edit it.
- **Automatic formatting**: at the start of a paragraph, type `- `, `1. `, `# `, `> ` or `[] ` and the paragraph becomes a list, numbered list, heading, quote or checklist. The full-width forms typed with Chinese input methods (`－ `, `1。 `, `＃ `, `》 `, `【】 `) work too.
- **Pasting**: text pasted from web pages or Word keeps bold, italic, links and so on. Formatting Markdown can't store, such as colors and fonts, is removed.
- **Links**: ⌘-click a link to open it; a normal click is for editing the text.

### Split view

- Edit the Markdown source on the left and see the live preview on the right. Both sides scroll together.
- **Syntax highlighting**: headings, bold, italic, code, links, lists, formulas and so on use different colors and fonts.
- **Math**: `$E=mc^2$` is an inline formula and `$$ … $$` a display formula, rendered with KaTeX. `==highlight==` and footnotes also preview correctly.

### For both views

- **Images**: images on your Mac are inserted with a path relative to the document when possible. To protect your privacy, **images from the web are not loaded**; local images display normally.
- **Auto save**: your edits are saved automatically, as in TextEdit. Use File → Revert To → Browse All Versions to get back an older version. A new untitled document asks where to save the first time it is saved.
- **Language**: choose the document language (Simplified Chinese, Traditional Chinese, Japanese, Korean) at the bottom left of the window. The same Chinese character is written differently in Chinese, Japanese and Korean; with the right language, characters use that language's shapes, in exported PDF / HTML files too. The default is “Automatic”: Japanese if the text has kana, Korean if it has Hangul, otherwise Simplified or Traditional Chinese based on your system language. A language you choose by hand is remembered for each file.
- **Export**: the Export button in the toolbar, or the Format menu:
  - **Export PDF**: A4 paper with automatic page breaks;
  - **Export HTML**: a single HTML file you can open in any browser. Local images are embedded in the HTML file, so they show wherever you save or send it; web images keep their original address (the browser loads them when you open the file).
- **Quick Look**: select a .md file in Finder and press Space to see it formatted (as in the Split view preview) without opening it.

---

## 3. Converting files

Click Convert Files in the toolbar, or choose File → Convert Files to Markdown… (⇧⌘T), to open the converter window.

1. **Add files**: drag files or whole folders into the window, or click Choose Files… / Choose Folders…. A folder brings in every supported file in all its subfolders.
2. **Choose a mode**:
   - **Fast**: uses MarkItDown and is quick. Good for Word, Excel, PowerPoint, HTML, CSV and text-based PDFs.
   - **High Accuracy**: uses Docling for layout analysis, table recognition and OCR. Good for papers, PDFs with tables or formulas, and scanned PDFs. **It applies to PDF files only**; other formats are converted in Fast mode.
3. **Word Engine** (optional): “Pandoc (better layout)” restores headings, lists, tables and other layout better. Both engines export the images in a Word file to a `filename_images` folder and link them from the Markdown with relative paths.
4. **OCR Engine** (High Accuracy mode): neither engine needs a download.
   - **RapidOCR (default)**: the PP-OCRv6 multilingual model, built into the app. It reads Simplified Chinese, Traditional Chinese, Japanese, English and more mixed on the same page, with no language to choose.
   - **Apple Vision**: the text recognition behind macOS Live Text, built into the system. It works with one East Asian language at a time, so you also choose a Main Language (Simplified Chinese / Traditional Chinese / Japanese; English is always included). Good for documents in one language; **for mixed Chinese and Japanese, use RapidOCR**.
5. **Recognize Math Formulas** (High Accuracy mode): turns formulas into LaTeX. It is slower and needs an extra model download the first time.
6. **Save To**:
   - by default, next to the original file, with the same name and a `.md` extension;
   - or choose “Chosen Folder”. Subfolders are kept when you drag in a folder.
7. Click **Convert**. The progress bar shows overall progress. Each file in the list shows Done / Failed / Skipped; when a file fails, the Details column explains why.
8. When it finishes, double-click a file in the list to open the Markdown in the editor, or right-click it and choose Show in Finder.

**Files with the same name**: if the `.md` file to be written already exists, DropMD asks first: replace, skip, replace all, skip all or cancel.

**Your original files are never changed**: DropMD only reads them and always writes new `.md` files (and image folders).

---

## 4. What happens the first time

- **Fast mode and Pandoc** work offline right away.
- **The first time you use High Accuracy mode**, a window lists the recognition models to download, the **source** and **size** of each, and where they will be saved. The download starts only if you click “Agree and Download”; “Cancel” downloads nothing.
  - Only Docling's layout model (about 172 MB), table model (about 358 MB) and the optional formula model (about 640 MB) are downloaded, from Docling's official Hugging Face account (`huggingface.co/docling-project`);
  - OCR needs no download: Apple Vision is part of macOS, and RapidOCR's models come from its PyPI package and are built into the app;
  - Models are saved in `~/Library/Application Support/DropMD/models`;
  - The download uses the macOS system network (the same network, DNS and proxy settings as Safari, including PAC and SOCKS proxies), contacts only huggingface.co and its download servers, and keeps no cookies. Every file is checked after downloading; if the download stops halfway, files already finished aren't downloaded again when you retry.
  - After that, conversions are fully offline. You can also download models or open the models folder from the High-Accuracy Recognition Models menu. To delete the models, delete that folder.
- The first High Accuracy conversion takes a while to load the models (tens of seconds, depending on your Mac); later ones are much faster.

---

## 5. Software updates

Choose DropMD → Check for Updates… to open the Software Update window:

- It shows the current version. Click Check Now to see if GitHub has a newer version and its release notes.
- If there is one, click Download and Update: DropMD downloads it and **checks its integrity**, then click Restart to switch to the new version (you are asked to save any unsaved documents first). After updating, old DropMD downloads in your Downloads folder are moved to the Trash. If DropMD isn't in a writable place such as Applications, the download opens instead; drag DropMD to Applications to replace the old version.
- **Check for updates automatically**: you are asked the first time DropMD starts. When it's on, DropMD checks each time it starts and tells you about new versions; you decide whether to download. Nothing is installed automatically.
- **Include beta versions**: also tells you about beta versions. It is on by default when you are running a beta.
- Checking for updates only asks GitHub for the version number and release notes, and never sends any files or personal information.

---

## 6. Privacy and security

- All conversions happen on your Mac. File contents are never uploaded to any server or online API.
- The conversion engine blocks every outgoing network connection internally (only communication within your Mac is allowed).
- DropMD goes online for only two things, both with your consent: downloading the High Accuracy recognition models, and checking for updates (asking GitHub for new versions). Both are done by the app through the macOS system network.
- No data collection, usage statistics or ads. Nothing is installed automatically.
- DropMD remembers your last settings (mode, output location and so on), stored only on your Mac.
- The Markdown preview has a strict content security policy: it can only read files on your Mac and blocks all network requests and scripts embedded in documents.
- For the open source components and their versions, see Help → Open Source Licenses → Third-Party Components, and `docs/依赖清单.md` in the project.

---

## 7. Open source licenses

DropMD is open source under the **MIT License** (see the `LICENSE` file): you are free to use, change and share it. The third-party components that come with it each follow their own license, for example Pandoc (GPL-2.0-or-later, run as a separate program). See `THIRD_PARTY_LICENSES.md` for details.

---

## 8. Known limits

- **Supported formats**: `.docx`, `.xlsx`, `.pptx`, `.html/.htm`, `.pdf` and `.csv`. Old Office formats (`.doc`, `.xls`, `.ppt`) aren't supported; save them in the newer format in Office first.
- **Encrypted or password-protected files** can't be converted.
- **Fast mode**: PDFs give text only, and complex layouts and tables may come out jumbled. Scanned PDFs have no text to extract (you'll be told to use High Accuracy mode).
- **High Accuracy mode**: needs a fair amount of memory (8 GB or more recommended), and large files can take several minutes. Handwriting and very blurry scans don't recognize well.
- **Liquid Glass** needs macOS 26 or later. On macOS 14–15 the app works the same, with ordinary translucent materials.
- **The Pandoc engine** is used for Word (.docx) files only.
- **Editor**: very large files (several MB) make syntax highlighting and the preview slower. The preview doesn't load images or fonts from the web.
- **Page view** keeps only formatting Markdown can store: fonts, font sizes, text colors, alignment and so on can't be saved (which is why the toolbar has no buttons for them). Text pasted from web pages or Word keeps bold, italic, links and so on; other formatting is removed when saving.
- Markdown that Page view doesn't support (for example general HTML code, nested collapsible sections, YAML front matter, reference link definitions, follow-on paragraphs and code blocks inside list items, lists inside quotes) is shown as monospaced text and **saved exactly as it was**, so nothing is lost.
- When you edit in Page view and save, some syntax is rewritten in an equivalent standard form: line breaks made with two trailing spaces or a backslash are saved as `<br>`, code indented by 4 spaces is saved as a ``` code block, `===` underlined headings are saved as `#` headings, `*` lists are saved as `-` lists, continuation lines in a quote get their missing `>`, and so on.
- The app is fairly large (see the actual build), mostly because of components such as PyTorch needed by High Accuracy mode.
- The app isn't signed with an Apple developer certificate, so the first launch needs the manual step described above.
- Intel Macs aren't supported (PyTorch, which High Accuracy mode depends on, no longer provides builds for Intel Macs).
- The network block applies to the conversion engine's Python code (including the Python parts of all conversion libraries). The Swift interface has network code in only two places, model downloads and update checks, both of which need your consent. For extra assurance, you can use firewall software to block DropMD from going online (and allow it only while downloading models or updating).

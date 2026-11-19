# 👋 Welcome to DropMD

DropMD is a Markdown editor for Mac. **You format text just like in Word**, and what you save is a standard Markdown file. It can also convert Word, Excel, PowerPoint, PDF and other files to Markdown.

> [!TIP]
> This guide is itself a Markdown document. Click around and edit it to try things out. You can't break it: every time you open it from **Help → DropMD User Guide**, you get a fresh copy.

## 🚀 Get started in 3 steps

- [ ] Choose **File → New** (⌘N) to create a document
- [ ] Type `# ` at the start of the first line, then your text: it becomes a heading. Press Return and write normally
- [ ] Select a few words and press ⌘B to make them bold. When you close the window, choose where to save, and you have a `.md` file

> [!NOTE]
> You don't need to know Markdown. What you see is the final result; the formatting is written as Markdown when you save.

## ✍️ Writing

### Page and Split

Switch between two views at the left end of the toolbar:

| View | Shortcut | Best for |
| --- | --- | --- |
| **Page** | ⌘1 | Formatting directly, like Word or Pages |
| **Split** | ⌘2 | Markdown source on the left, Page on the right; edit either side, and text and scrolling stay in sync |

When you move the cursor on the left in Split view, the right side marks the matching position. To turn this off or choose another marker style (Border, Side Bar, Cursor), go to **DropMD → Settings… → General**. Drag the divider in the middle to resize; double-click it to split evenly again.

### Formatting as you type

Type one of these at the start of a paragraph, then press Space:

| Type | You get |
| --- | --- |
| `# ` `## ` `### ` | Heading 1, 2, 3 |
| `- ` or `* ` | Bulleted list |
| `1. ` | Numbered list |
| `[] ` | Checklist (click the box to tick it) |
| `> ` | Quote |

### Common shortcuts

| Action | Shortcut |
| --- | --- |
| Bold / Italic / Underline | ⌘B / ⌘I / ⌘U |
| Strikethrough / Highlight | ⇧⌘X / ⇧⌘H |
| Inline Code | ⌥⌘C |
| Heading 1–6 / Body | ⌥⌘1–⌥⌘6 / ⌥⌘0 |
| Link / Image | ⌘K / ⇧⌘K |
| Table | ⌥⌘T |
| Indent / Outdent | Tab / ⇧Tab (in a list) |
| Line break in the same paragraph | ⇧↩ |
| Show the Format panel | ⌥⌘I |

Every command is also in the **Format** and **Insert** menus. The Format panel on the right shows the style at the cursor; click to change it.

### Context menu

Right-click something to get the actions you need most for it:

- **Table**: insert or delete rows and columns, Alignment, Copy Table, Delete Table
- **Link**: open, edit, copy, remove
- **Image**: Edit Alt Text, Show in Finder, Delete Image
- **Code block**: Copy Code, choose the language
- **Callout**: change the type, Convert to Quote
- **Selected text**: Strikethrough, Highlight, Inline Code, Clear Formatting

## 📦 Inserting things

Use the buttons in the middle of the toolbar or the **Insert** menu.

### Tables

- Press Tab or Return to move to the next cell. In the last cell, Tab adds a row and Return moves below the table
- Drag the line between two columns to change their width
- Select whole rows and press Delete to remove them. At the start of the paragraph below a table, press Delete twice to remove the whole table (the first press selects it, so nothing is deleted by accident)

### Callouts

The colored boxes you see here are callouts. There are five types: Note, Tip, Important, Warning and Caution.

> [!IMPORTANT]
> Callouts also show as colored boxes on GitHub and in Obsidian.

### Code blocks

After you make a paragraph a code block, choose its language from the context menu. Move the pointer over a code block and a Copy button appears at the top right:

```swift
print("Hello, DropMD!")
```

### Collapsible sections

<details>
<summary>Click here to expand</summary>

A collapsible section hides its content until you open it. Click the triangle before the title to expand or collapse it. The shortcut to insert one is ⇧⌘D.

</details>

### Formulas, footnotes and more

- **Formulas**: Inline Formula ⌥⌘M, Formula Block ⇧⌥⌘M, written in LaTeX, for example $E=mc^2$. Double-click a formula to edit it
- **Footnotes**: ⌥⌘F inserts a number at the cursor and puts the note at the end of the document
- **Images**: images on your Mac are linked with a path relative to the document when possible. To protect your privacy, **images from the web are not loaded**
- **Today's Date** and **Emoji & Symbols**: in the **Insert** menu

## 🔗 Links

By default, clicking a link asks before opening it, so you don't open it by mistake when you only want to edit its text. To change this, go to **DropMD → Settings… → General → When Clicking a Link** and choose **Open Immediately** or **Open Only with ⌘-Click**. ⌘-click always opens the link right away.

A link to another `.md` file opens it in DropMD; a link to any other file shows it in Finder.

## 📤 Saving, exporting and sharing

- **Autosave**: your work is saved automatically, as in TextEdit. To get back an earlier version, choose **File → Revert To → Browse All Versions…**
- **Export**: the Export button in the toolbar saves a **PDF** (A4 paper) or **HTML** (images on your Mac are embedded in the HTML file, so they show anywhere)
- **Share**: the Share button sends the `.md` file via AirDrop, Mail, Messages and more
- **Quick Look**: select a `.md` file in Finder and press Space to see it formatted without opening it

> [!TIP]
> At the bottom left of the window you can set the document language (Simplified Chinese, Traditional Chinese, Japanese, Korean). The same Chinese character is drawn differently in each, so the right choice makes the characters look right.

## 🔄 Converting files to Markdown

Choose **File → Convert Files to Markdown…** (⇧⌘T) to open the converter:

1. Drag files or whole folders into the window, or click **Choose Files…**
2. Choose a mode:
   - **Fast**: for Word, Excel, PowerPoint, HTML, CSV and PDFs with selectable text
   - **High Accuracy**: for papers, scanned PDFs and PDFs with tables or formulas (PDF only)
3. Click **Convert**. When it's done, double-click a file in the list to open it in DropMD

The `.md` file is saved next to the original by default, and images from Word go into a "filename_images" folder. **Your original files are never changed.**

> [!NOTE]
> The first time you use High Accuracy, DropMD needs to download recognition models (about 530 MB, plus about 640 MB with **Recognize Math Formulas**). It shows where they come from and how big they are, and downloads only after you agree. After that, everything works offline.

| OCR engine (High Accuracy) | What it's good at |
| --- | --- |
| **RapidOCR** (default) | Simplified and Traditional Chinese, Japanese and English mixed on one page |
| **Apple Vision** | Built into macOS; for documents in one language (you choose the main language) |
| **Xiaomi-OCR-0** | More accurate and reads formulas and tables too; a 1.8 GB download the first time, and slower |

## ⚙️ Settings

**DropMD → Settings…** (⌘,) has four tabs:

| Tab | What you can do |
| --- | --- |
| **General** | Appearance (light or dark), Page Margins, When Clicking a Link, the Split view marker, Language, make DropMD the default app for `.md` files |
| **Updates** | Check for new versions, check automatically at startup, include beta versions |
| **Support** | If you like DropMD, buy the author a coffee |
| **About** | Version, GitHub repository, report an issue, community, open-source licenses |

> [!TIP]
> New versions come as betas first. To try new features early, turn on **Include beta versions** in the Updates tab.

## 🔒 Privacy

- Everything you edit and convert stays on your Mac; no file is ever uploaded
- DropMD goes online for only two things, and only with your OK: downloading the High Accuracy models and checking for updates
- No data collection, usage statistics or ads, and nothing is installed automatically

## ❓ Questions

<details>
<summary>Some formatting disappeared after saving?</summary>

Markdown can store things like bold, italic, headings, lists and tables. Fonts, font sizes, text colors and alignment can't be stored, so the toolbar has no buttons for them. When you paste from a web page or Word, bold, italic and links are kept and the rest is removed.

</details>

<details>
<summary>Some content shows in a monospaced font?</summary>

Markdown that Page view doesn't support yet (such as general HTML code or YAML at the top of a file) shows this way and is saved exactly as it was, so nothing is lost. Switch to Split view to edit it on the left.

</details>

<details>
<summary>Which files can be converted?</summary>

`.docx`, `.xlsx`, `.pptx`, `.html`, `.pdf` and `.csv`. Save old Office files (`.doc`, `.xls`, `.ppt`) in the new format first. Encrypted or password-protected files can't be converted.

</details>

<details>
<summary>Where can I report a problem?</summary>

**Help → Report an Issue…** opens the issues page on GitHub. You can also join the community from **Help → Join the Discord Community…**.

</details>

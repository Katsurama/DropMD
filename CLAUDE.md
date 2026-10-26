# DropMD 开发须知（给 Claude Code）

当前进度、待办和已知问题见 [docs/交接说明.md](docs/交接说明.md)，开始工作前先读。

## 与用户沟通

- 用户用中文提问就用中文回答，用日语提问就用日语回答。
- 用户面向的是不懂技术的普通用户：界面文字、提示、文档都用简单的中文。
- 界面改动要有截图依据（见下文“验证界面”），不要没看到实际效果就说“没问题”。

## 必须遵守

- **安全与隐私第一**：App 的联网行为只有两种，都要用户同意：下载高精度识别模型、检查更新。不加统计；只在用户点击“下载并更新”“重新启动”后才安装新版本。
- **代码、文档、提交中不能出现用户的个人信息**（真名、邮箱、本机路径、主机名等）。版权署名用 “DropMD contributors”。
- **提交作者不能用用户的真名**。
- **不开 PR、不新建分支**：直接在默认分支 `main` 上提交、推送。
- **仓库是公开的**：推送前先征得用户同意。
- 改写历史、强制推送、删除标签等不可撤销的操作，先征得用户同意。
- 不要伪造文献、数据或测试结果；没验证过的事要明说。

## 项目结构

- `macos/Sources/DropMD/`：Swift / SwiftUI 界面（macOS 14+）
  - `MarkdownCodec` / `MarkdownInline` / `MarkdownSerialize`：Markdown ⇄ 段落模型，只依赖 Foundation
  - `RichBridge` / `RichStyle` / `RichTextView` / `RichEditorView`：单页（Word / Pages 式）编辑区，TextKit 1
  - `EditorViews` / `EditorController`：编辑器窗口、双页（原文 + 预览）
  - `EditorAction`：所有命令（菜单、工具栏、格式面板共用这一份）
  - `FormatInspector`：右侧“格式”面板
  - `UpdateChecker` / `UpdateView` / `AppUpdateInstaller`：软件更新（下载后替换并重启）
- `macos/Resources/preview/`：双页预览（markdown-it + 插件 + KaTeX，全部本地文件）
- `src/dropmd/`：文件转换引擎（Python：MarkItDown / Pandoc / Docling）。用户同意保留 Python。

## 构建与测试

```bash
tools/test_codec.sh                    # Markdown 往返测试（改了 Markdown*.swift 必须跑）
tools/test_editor.sh                   # 单页编辑器按键测试（改了 Rich*.swift 必须跑）
tools/test_update.sh                   # 软件更新的安装测试（改了 AppUpdateInstaller.swift 必须跑）
cd macos && swift build                # 编译界面（本机需完整的 Xcode；Xcode 27 加 --build-system native，
                                       # 否则程序记录的 SDK 版本不对，Liquid Glass 不启用）
cd macos && swift run DropMD           # 只看界面（没有转换引擎和预览资源）

# 完整构建（与发布版相同）
tools/build_local.sh                   # 本机完整构建：测试、引擎、App、.dmg、.zip（需要 brew 的 python@3.12）
tools/build_local.sh vX.Y.Z-beta.N     # 构建后直接创建 GitHub Release（gh 通过 1Password 插件登录，会弹 Touch ID）
```

## 图标

- `macos/Resources/AppIcon.icon` 是 Icon Composer 格式（可用 Xcode 自带的 Icon Composer 打开编辑）。改图标后在本机运行 `macos/make_icon.sh`，把 `macos/Resources/AppIcon.compiled`（Assets.car、AppIcon.icns）一起提交。
- 构建时直接复制编译好的图标，不在 GitHub 上编译：构建机上 Xcode 26 的 actool 编译这个图标会崩溃。
- 预览各样式：`"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" macos/Resources/AppIcon.icon --export-image --output-file out.png --platform macOS --rendition Dark --width 256 --height 256 --scale 1`（rendition：Default / Dark / ClearLight / TintedDark）。

## 验证界面

- 本地：直接运行 App，用 `packaging/samples/editor_sample.md`（包含所有格式）检查单页 / 双页、浅色 / 深色。
- 菜单“显示 → 外观”可强制浅色 / 深色。
- GitHub Actions 构建会自动截图 `shots/{rich,source}-{Light,Dark}.png`，在构件 `selftest-macOS` 中。

## 发布新版本

1. 改版本号：`macos/Resources/Info.plist`（CFBundleShortVersionString、CFBundleVersion）、`src/dropmd/__init__.py`、`README.md`。
2. 在 `docs/发行说明.md` 最上面加本版说明（发布时整份文件作为 Release 说明）。
3. **默认在 GitHub Actions 上构建**（公开仓库不计分钟数）：提交并推送后，先不带版本号触发构建、检查截图
   （`gh workflow run build.yml --repo Katsurama/DropMD --ref main`）；没问题再带版本号触发
   （加 `-f release_tag=vX.Y.Z-beta.N`），构建完自动创建 Release。带 `-` 的版本自动标为预发布。
   `tools/build_local.sh vX.Y.Z-beta.N` 只在 GitHub 上无法构建时使用。
4. 用户希望直接发布新版、在 App 内升级，不需要单独发安装包（除非用户要求）。

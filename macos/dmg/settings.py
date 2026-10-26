# dmgbuild 配置：生成带背景图、图标布局和“拖到应用程序”提示的安装盘。
# 用法：
#   dmgbuild -s macos/dmg/settings.py \
#     -D app=dist/DropMD.app -D background=build/dmg/background.tiff \
#     "DropMD" DropMD-macOS-AppleSilicon.dmg
import os

app = defines["app"]  # noqa: F821（dmgbuild 注入）
app_name = os.path.basename(app)

# 压缩格式：ULFO（LZFSE，macOS 10.11+），体积比传统 UDZO 更小
format = "ULFO"
filesystem = "HFS+"
size = None

files = [app]
symlinks = {"应用程序": "/Applications"}
hide_extension = [app_name]

# 磁盘卷图标使用 App 自身的图标
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")

# 窗口外观：与 make_background.swift 的 660×420 背景图一致
background = defines["background"]  # noqa: F821
window_rect = ((200, 140), (660, 420))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

icon_size = 112
text_size = 13
arrange_by = None
grid_spacing = 100
label_pos = "bottom"
icon_locations = {
    app_name: (170, 200),
    "应用程序": (490, 200),
}

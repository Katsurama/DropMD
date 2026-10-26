// 生成 App 图标的前景图层（arrow.down.doc 符号与“MD”），写入 Resources/AppIcon.icon/Assets。
// 背景色、玻璃效果、深色样式等在 Resources/AppIcon.icon/icon.json 中设置（Icon Composer 格式），
// 改图案后运行 make_icon.sh（会调用本文件并用 actool 编译）。
import AppKit

let assets = URL(fileURLWithPath: "Resources/AppIcon.icon/Assets")

func layer(_ name: String, _ draw: (CGFloat) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(1024)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: assets.appendingPathComponent("\(name).png"))
}

layer("doc") { s in
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.46, weight: .semibold).applying(.init(paletteColors: [.white]))
    let sym = NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
    let sz = sym.size
    sym.draw(in: NSRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2 + s * 0.05, width: sz.width, height: sz.height))
}
layer("md") { s in
    let md = NSAttributedString(string: "MD", attributes: [
        .font: NSFont.systemFont(ofSize: s * 0.12, weight: .heavy), .foregroundColor: NSColor.white])
    let sz = md.size()
    md.draw(at: NSPoint(x: (s - sz.width) / 2, y: s * 0.13))
}

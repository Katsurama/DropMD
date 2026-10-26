// 生成 DMG 窗口背景图（660×420 点），同时输出 1x 与 2x（Retina）两种分辨率。
// 用法：swift make_background.swift 输出目录
// 图标位置需与 settings.py 保持一致：App 在 (170, 200)，“应用程序”在 (490, 200)。
import AppKit

let W: CGFloat = 660, H: CGFloat = 420
let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H) // 让 2x 图片带有正确的 144 dpi 信息
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    // 坐标换算：设计稿以左上角为原点
    func y(_ top: CGFloat) -> CGFloat { H - top }

    // 背景：柔和的浅色渐变 + 两处淡淡的彩色光晕（呼应 Liquid Glass 风格）
    NSGradient(colors: [NSColor(red: 0.965, green: 0.972, blue: 0.988, alpha: 1),
                        NSColor(red: 0.905, green: 0.925, blue: 0.965, alpha: 1)])!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)
    for (cx, cy, r, color) in [(110.0, 70.0, 220.0, NSColor(red: 0.25, green: 0.55, blue: 1.0, alpha: 0.10)),
                               (560.0, 380.0, 240.0, NSColor(red: 0.55, green: 0.35, blue: 0.95, alpha: 0.09))] {
        let g = NSGradient(colors: [color, color.withAlphaComponent(0)])!
        g.draw(fromCenter: NSPoint(x: cx, y: y(cy)), radius: 0, toCenter: NSPoint(x: cx, y: y(cy)), radius: r,
               options: [])
    }

    func text(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, top: CGFloat) {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        let a = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color, .paragraphStyle: p,
        ])
        let h = a.size().height
        a.draw(in: NSRect(x: 20, y: y(top) - h, width: W - 40, height: h))
    }

    text("DropMD", size: 24, weight: .bold, color: NSColor(white: 0.12, alpha: 1), top: 34)
    text("离线 Markdown 编辑器 · 文件转换", size: 12.5, weight: .regular, color: NSColor(white: 0.42, alpha: 1), top: 68)

    // 箭头：从 App 图标指向“应用程序”文件夹
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 258, y: y(200)))
    arrow.curve(to: NSPoint(x: 398, y: y(200)),
                controlPoint1: NSPoint(x: 300, y: y(182)), controlPoint2: NSPoint(x: 356, y: y(182)))
    arrow.lineWidth = 3.5
    arrow.lineCapStyle = .round
    let arrowColor = NSColor(red: 0.20, green: 0.48, blue: 0.95, alpha: 0.85)
    arrowColor.setStroke()
    let dash: [CGFloat] = [1, 9]
    arrow.setLineDash(dash, count: 2, phase: 0)
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 386, y: y(189)))
    head.line(to: NSPoint(x: 402, y: y(200)))
    head.line(to: NSPoint(x: 386, y: y(211)))
    head.lineWidth = 3.5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    text("将 DropMD 拖到“应用程序”文件夹即可完成安装", size: 14, weight: .medium,
         color: NSColor(white: 0.20, alpha: 1), top: 318)
    text("首次打开若提示无法验证开发者：系统设置 → 隐私与安全性 → 仍要打开", size: 11,
         color: NSColor(white: 0.45, alpha: 1), top: 346)
    text("所有转换均在本机完成，不上传任何文件", size: 11, weight: .regular,
         color: NSColor(red: 0.15, green: 0.55, blue: 0.30, alpha: 1), top: 366)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try! render(scale: 1).write(to: outDir.appendingPathComponent("background.png"))
try! render(scale: 2).write(to: outDir.appendingPathComponent("background@2x.png"))
print("ok")

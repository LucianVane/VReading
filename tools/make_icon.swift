// 生成 VReading 图标: 翻开的书 (轮廓呈 "M") + 声波, 祖母绿 -> 天蓝渐变
// 用法: swift tools/make_icon.swift <工程根目录>
import AppKit

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let assets = root + "/VReading/Resources/Assets.xcassets"
let size: CGFloat = 1024

func c(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// 背景: 对角渐变 + 左上柔光
NSGradient(colors: [c(0x22C55E), c(0x10B981), c(0x0EA5E9)], atLocations: [0, 0.45, 1], colorSpace: .deviceRGB)!
    .draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -50)
NSGradient(colors: [c(0xFFFFFF, 0.22), c(0xFFFFFF, 0)])!
    .draw(fromCenter: NSPoint(x: 260, y: 820), radius: 0, toCenter: NSPoint(x: 260, y: 820), radius: 620, options: [])

let cx: CGFloat = 512
let bottom: CGFloat = 250, outerTop: CGFloat = 690, spineTop: CGFloat = 560, w: CGFloat = 330

/// 一页书: 外沿竖直, 上沿从外侧高点弧形下凹到书脊, 两页合起来轮廓呈 "M"
func page(_ dir: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: cx + dir * 10, y: bottom))
    p.curve(to: NSPoint(x: cx + dir * w, y: bottom + 34),
            controlPoint1: NSPoint(x: cx + dir * 120, y: bottom + 40), controlPoint2: NSPoint(x: cx + dir * 240, y: bottom + 6))
    p.line(to: NSPoint(x: cx + dir * w, y: outerTop))
    p.curve(to: NSPoint(x: cx + dir * 10, y: spineTop),
            controlPoint1: NSPoint(x: cx + dir * 230, y: outerTop + 24), controlPoint2: NSPoint(x: cx + dir * 90, y: outerTop - 10))
    p.close()
    return p
}

// 书页 + 柔和投影
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: c(0x064E3B, 0.35).cgColor)
c(0xFFFFFF).setFill()
page(-1).fill()
page(1).fill()
ctx.restoreGState()
c(0xE6FFFA).setFill()
page(1).fill()

// 正文行
for (i, frac) in [CGFloat(0.78), 0.70, 0.74, 0.55].enumerated() {
    let y = spineTop - 70 - CGFloat(i) * 62
    let lw = (w - 110) * frac
    c(0x10B981, 0.55).setFill()
    NSBezierPath(roundedRect: NSRect(x: cx - 60 - lw, y: y, width: lw, height: 24), xRadius: 12, yRadius: 12).fill()
    c(0x0EA5E9, 0.5).setFill()
    NSBezierPath(roundedRect: NSRect(x: cx + 60, y: y, width: lw, height: 24), xRadius: 12, yRadius: 12).fill()
}

// 声波: 代表播客 / 听力
let wave = NSPoint(x: cx + 250, y: 760)
for (i, r) in [CGFloat(52), 104, 156].enumerated() {
    let arc = NSBezierPath()
    arc.appendArc(withCenter: wave, radius: r, startAngle: -10, endAngle: 70)
    arc.lineWidth = 30
    arc.lineCapStyle = .round
    c(0xFFFFFF, 1 - CGFloat(i) * 0.25).setStroke()
    arc.stroke()
}
c(0xFFFFFF).setFill()
NSBezierPath(ovalIn: NSRect(x: wave.x - 22, y: wave.y - 22, width: 44, height: 44)).fill()

NSGraphicsContext.restoreGraphicsState()

// App 图标不能带透明通道
let flat = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
flat.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: size, height: size))
let image = flat.makeImage()!

func write(_ img: CGImage, _ px: Int, _ path: String) {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: px, height: px))
    try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

write(image, 1024, assets + "/AppIcon.appiconset/icon-1024.png")
write(image, 384, assets + "/Logo.imageset/logo.png")
print("icon written")

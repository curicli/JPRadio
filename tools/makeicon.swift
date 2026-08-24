import AppKit

// 1024×1024 应用图标：暖橙渐变底 + 居中广播波纹（((•))）。
// 用不透明上下文（noneSkipLast），输出无 alpha 通道的 PNG，避免 App Store 图标告警。

let px = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let S = CGFloat(px)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r/255, green: g/255, blue: b/255, alpha: a)
}

// 背景渐变（左上更亮的暖橙 → 右下深红橙）
let bg = CGGradient(colorsSpace: cs,
                    colors: [rgb(255, 150, 74), rgb(226, 46, 22)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])

// 顶部柔光
let glow = CGGradient(colorsSpace: cs,
                      colors: [rgb(255, 255, 255, 0.22), rgb(255, 255, 255, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow,
                       startCenter: CGPoint(x: S * 0.5, y: S * 0.6), startRadius: 0,
                       endCenter: CGPoint(x: S * 0.5, y: S * 0.6), endRadius: S * 0.6,
                       options: [])

// 广播波纹：以中心点为圆心，向左右两侧各画三道弧线
let cx = S * 0.5
let cy = S * 0.52          // CG 原点在左下；略偏上更居中于视觉
let radii: [CGFloat] = [150, 292, 434]
let widths: [CGFloat] = [42, 37, 32]
let alphas: [CGFloat] = [1.0, 0.72, 0.46]
let spread = CGFloat.pi / 4.3   // 每侧张角

ctx.setLineCap(.round)
for i in 0..<radii.count {
    ctx.setStrokeColor(rgb(255, 255, 255, alphas[i]))
    ctx.setLineWidth(widths[i])
    // 右侧
    ctx.beginPath()
    ctx.addArc(center: CGPoint(x: cx, y: cy), radius: radii[i],
               startAngle: -spread, endAngle: spread, clockwise: false)
    ctx.strokePath()
    // 左侧
    ctx.beginPath()
    ctx.addArc(center: CGPoint(x: cx, y: cy), radius: radii[i],
               startAngle: .pi - spread, endAngle: .pi + spread, clockwise: false)
    ctx.strokePath()
}

// 中心圆点
ctx.setFillColor(rgb(255, 255, 255))
ctx.fillEllipse(in: CGRect(x: cx - 62, y: cy - 62, width: 124, height: 124))

// 导出 PNG
let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
let data = rep.representation(using: .png, properties: [:])!
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
try! data.write(to: URL(fileURLWithPath: out))
print("wrote \(out) (\(data.count) bytes)")

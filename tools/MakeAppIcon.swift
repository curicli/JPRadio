// App 图标生成器（在 Mac 上跑；放在 ios/JPRadio/ 之外，故不会被编译进 iOS target）。
//
//   SDK=/Applications/xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
//   swiftc -sdk "$SDK" -O -o /tmp/makeicon Tools/MakeAppIcon.swift
//   /tmp/makeicon ios/JPRadio/Assets.xcassets/AppIcon.appiconset/AppIcon.png
//
// 设计：**モダン・バウハウス**（现代包豪斯）。
// 几何原形 + 三原色 + 完全平涂，没有渐变、没有高光、没有阴影 —— 包豪斯的规矩。
// 一点（送信点）从基准线向上放出同心半円：既是「電波」，也是包豪斯招牌的嵌套半圆。
// 环带由内向外逐渐变窄，像水面涟漪扩散；最外圈刻意溢出画布左右两边，
// 让构图有现代海报的张力，而不是一个居中的小圆。
// 元素只有五个：底色 / 半円環 / 基準線 / 送信点 / 支柱，40px 下也认得出。
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let S: CGFloat = 1024

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// バウハウスの三原色（少しだけ現代寄りに彩度を落とす）
let paper  = rgb(0xF2EDE4)   // 生成り
let blue   = rgb(0x1E4FA1)   // コバルト
let red    = rgb(0xD93B2B)   // 朱赤
let yellow = rgb(0xF0B429)   // 山吹
let ink    = rgb(0x15161A)   // ほぼ黒

// App 图标必须**不带 alpha 通道**（否则 App Store 校验会报错），
// 故用 noneSkipLast 而不是 premultipliedLast —— 画面本来就铺满不透明像素。
guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S),
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("cannot create context")
}

// MARK: - 1. 底色（平涂）
ctx.setFillColor(paper)
ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))

// MARK: - 2. 同心半円（CG 座標は y が上向き。送信点は基準線の上）
let origin = CGPoint(x: S * 0.5, y: S * 0.17)

/// 上半分だけの円（弦は基準線と一致）を平涂。
func fillHalfDisc(radius: CGFloat, color: CGColor) {
    ctx.setFillColor(color)
    ctx.beginPath()
    ctx.addArc(center: origin, radius: radius, startAngle: 0, endAngle: .pi, clockwise: false)
    ctx.closePath()
    ctx.fillPath()
}

// 大 → 小の順に重ね塗り。紙色を挟むことで「環」になり、涟漪に見える。
// 帯幅は内側ほど太い（0.11 → 0.13 → 0.15 → 0.15 → 芯 0.21）。
for (radius, color) in [(0.755, blue), (0.645, paper), (0.515, red), (0.365, paper), (0.210, yellow)] {
    fillHalfDisc(radius: S * CGFloat(radius), color: color)
}

// MARK: - 3. 基準線 / 支柱 / 送信点
ctx.setFillColor(ink)
// 基準線：画面いっぱいに引いて構図を締める。
ctx.fill(CGRect(x: 0, y: origin.y - S * 0.012, width: S, height: S * 0.024))
// 支柱：基準線から下へ。半円が「立っている」ことがわかる。
ctx.fill(CGRect(x: origin.x - S * 0.010, y: S * 0.045, width: S * 0.020, height: S * 0.125))
// 送信点：すべての円の中心。
let dotR = S * 0.050
ctx.fillEllipse(in: CGRect(x: origin.x - dotR, y: origin.y - dotR, width: dotR * 2, height: dotR * 2))

// MARK: - 書き出し
guard let image = ctx.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: S, height: S)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try data.write(to: URL(fileURLWithPath: out))
print("wrote \(out) — \(data.count) bytes")

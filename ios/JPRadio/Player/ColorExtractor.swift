import SwiftUI
import UIKit

/// 从电台台标提取一个「品牌主色」，用于驱动背景渐变（类似 Apple Music 的观感）。
/// 结果按 station id 缓存；界面观察本 store 即可拿到颜色。
@MainActor
final class PaletteStore: ObservableObject {
    @Published private(set) var colors: [String: Color] = [:]

    /// 默认主色（尚未取到台标时使用）。
    static let fallback = Color(red: 0.20, green: 0.22, blue: 0.30)

    func color(for station: Station) -> Color {
        colors[station.id] ?? Self.fallback
    }

    func load(for station: Station) {
        guard colors[station.id] == nil, let url = station.logoURL else { return }
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data),
                  let uiColor = image.vibrantColor() else { return }
            await MainActor.run {
                self?.colors[station.id] = Color(uiColor).adjustedForBackground()
            }
        }
    }
}

private extension Color {
    /// 压暗、限制过亮，得到适合做深色背景的色调。
    func adjustedForBackground() -> Color {
        let ui = UIColor(self)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        let newS = min(s * 1.15, 0.85)
        let newB = min(max(b * 0.75, 0.30), 0.62)
        return Color(hue: Double(h), saturation: Double(newS), brightness: Double(newB))
    }
}

extension UIImage {
    /// 在一个小网格上采样，挑选饱和度最高、明度适中的像素作为主色；
    /// 忽略近白 / 近黑 / 透明像素（台标底色多为白色，直接取平均会发灰）。
    func vibrantColor(sampleDimension n: Int = 16) -> UIColor? {
        guard let cg = cgImage else { return nil }
        var buffer = [UInt8](repeating: 0, count: n * n * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: &buffer, width: n, height: n, bitsPerComponent: 8,
                                  bytesPerRow: n * 4, space: colorSpace, bitmapInfo: bitmapInfo) else {
            return nil
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))

        var bestScore: CGFloat = -1
        var best: UIColor?
        var rSum: CGFloat = 0, gSum: CGFloat = 0, bSum: CGFloat = 0, count: CGFloat = 0

        for i in stride(from: 0, to: buffer.count, by: 4) {
            let a = CGFloat(buffer[i + 3]) / 255
            if a < 0.5 { continue }
            let r = CGFloat(buffer[i]) / 255
            let g = CGFloat(buffer[i + 1]) / 255
            let b = CGFloat(buffer[i + 2]) / 255
            rSum += r; gSum += g; bSum += b; count += 1

            let maxC = max(r, g, b), minC = min(r, g, b)
            let brightness = maxC
            let saturation = maxC == 0 ? 0 : (maxC - minC) / maxC
            // 跳过近白与近黑
            if brightness > 0.93 && saturation < 0.12 { continue }
            if brightness < 0.10 { continue }

            let score = saturation * (0.4 + brightness * 0.6)
            if score > bestScore {
                bestScore = score
                best = UIColor(red: r, green: g, blue: b, alpha: 1)
            }
        }

        if let best, bestScore > 0.12 { return best }
        guard count > 0 else { return nil }
        return UIColor(red: rSum / count, green: gSum / count, blue: bSum / count, alpha: 1)
    }
}

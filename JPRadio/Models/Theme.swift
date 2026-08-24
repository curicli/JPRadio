import SwiftUI

/// 主题色。
///
/// **为什么不用 `Color.accentColor`**：那个值来自 asset catalog 里的 `AccentColor.colorset`，
/// 而 asset catalog 要靠 `actool` 编成 `Assets.car` 才生效 —— 手工打的未签名 ipa
/// （见 `tools/make_unsigned_ipa.sh`）里没有这一步，`accentColor` 会静静退回系统蓝，
/// 整个界面的强调色全变样。写成代码里的常量，两种打包路径拿到的都是同一个色。
///
/// 值与 `JPRadio/Assets.xcassets/AccentColor.colorset` 保持一致（sRGB 1.000 / 0.400 / 0.180，
/// 即 #FF662E）—— colorset 仍然留着，Xcode 正常构建时它负责 tab bar 之类的系统着色。
extension Color {
    /// 品牌橙红 #FF662E。界面里所有强调色都用它（原先写 `Color.accentColor` 的地方）。
    static let brand = Color(red: 1.0, green: 0.40, blue: 0.18)
}

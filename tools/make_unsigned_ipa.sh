#!/bin/zsh
# 导出未签名 ipa（不经 xcodebuild）。
#
# 为什么不用 xcodebuild：本机这套环境里 xcodebuild / actool 一启动就去连 CoreSimulator
# 的 XPC 服务，连不上直接被 SIGTERM/SIGABRT 掉（日志里满屏 simdiskimaged / SimServiceContext
# 报错）。所以这里绕开整套构建服务，直接 swiftc 编链出可执行文件，再手工拼 .app 与 Payload。
#
# 代价（与 Xcode Archive 出来的包相比）：
#   - **没有 Assets.car**（actool 跑不起来）→ asset catalog 里的颜色/图片在运行时取不到。
#     强调色因此**不再走 `Color.accentColor`**，改成代码常量 `Color.brand`（见
#     ios/JPRadio/Models/Theme.swift），这样手工包和 Xcode 包配色一致；台标之类的运行时
#     下载图片本来就不受影响。app 图标改用旧式 `CFBundleIconFiles`（现切 120/180/1024
#     三张 PNG）—— 这条路 iOS 至今仍认，图标能正常显示。
#   - 未签名：装机需自行用 Sideloadly / AltStore / 自签工具签一次。
#
# 用法：zsh tools/make_unsigned_ipa.sh   → 产出仓库根目录的 JPRadio-unsigned.ipa
set -e
setopt globstardot 2>/dev/null || true

ROOT=${0:a:h:h}
cd "$ROOT"

DEV=/Applications/xcode.app/Contents/Developer
SWIFTC=$DEV/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
SDK=$DEV/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk
STAGE=${TMPDIR:-/tmp}/jpradio-ipa
APP=$STAGE/Payload/JPRadio.app

rm -rf "$STAGE"
mkdir -p "$APP"

# 1. 编译 + 链接（-parse-as-library：入口是 @main struct，不是 main.swift 的顶层代码）
FILES=(ios/JPRadio/**/*.swift)
echo "compiling ${#FILES[@]} files…"
"$SWIFTC" -sdk "$SDK" -target arm64-apple-ios17.0 -O -wmo -parse-as-library \
  -module-cache-path "${TMPDIR:-/tmp}/mcache" -disable-sandbox \
  -o "$APP/JPRadio" "${FILES[@]}"

# 2. app 图标：从 1024 母图切出旧式图标（actool 用不了，见文件头；sips 也不行，见 ResizePNG.swift）
ICON=ios/JPRadio/Assets.xcassets/AppIcon.appiconset/AppIcon.png
MACSDK=$DEV/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
RESIZE=${TMPDIR:-/tmp}/resizepng
"$SWIFTC" -sdk "$MACSDK" -O -module-cache-path "${TMPDIR:-/tmp}/mcache" -disable-sandbox \
  -o "$RESIZE" tools/ResizePNG.swift
for size in 120 180; do
  "$RESIZE" "$ICON" "$APP/AppIcon${size}.png" $size
done
cp "$ICON" "$APP/AppIcon1024.png"

# 3. Info.plist：把 $(...) 构建变量替换成真值，并补上装机必需的键
python3 tools/fill_info_plist.py ios/JPRadio/Info.plist "$APP/Info.plist"

# 4. 打包（ipa 就是个 zip，根目录一个 Payload/）
( cd "$STAGE" && zip -qry "$ROOT/JPRadio-unsigned.ipa" Payload )
echo "→ $ROOT/JPRadio-unsigned.ipa"
ls -lh "$ROOT/JPRadio-unsigned.ipa"

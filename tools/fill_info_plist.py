#!/usr/bin/env python3
"""把 JPRadio/Info.plist 里的 $(构建变量) 换成真值，并补齐装机必需的键。

Xcode 打包时这一步由 ProcessInfoPlistFile 干；这里手工拼包（见 make_unsigned_ipa.sh），
所以自己来。变量的真值从 project.pbxproj 里那套 build settings 抄下来。
"""
import plistlib
import subprocess
import sys

SUBSTITUTIONS = {
    "$(DEVELOPMENT_LANGUAGE)": "en",
    "$(EXECUTABLE_NAME)": "JPRadio",
    "$(PRODUCT_BUNDLE_IDENTIFIER)": "com.mingqi.JPRadio",
    "$(PRODUCT_NAME)": "JPRadio",
    "$(PRODUCT_BUNDLE_PACKAGE_TYPE)": "APPL",
    "$(MARKETING_VERSION)": "1.0",
    "$(CURRENT_PROJECT_VERSION)": "1",
}


def resolve(value):
    if isinstance(value, str):
        return SUBSTITUTIONS.get(value, value)
    if isinstance(value, dict):
        return {k: resolve(v) for k, v in value.items()}
    if isinstance(value, list):
        return [resolve(v) for v in value]
    return value


def main(src, dst):
    with open(src, "rb") as f:
        info = resolve(plistlib.load(f))

    # 装机必需 / Xcode 平时自动写进去的那几个键。
    # MinimumOSVersion 缺了 iOS 会直接拒装（不是警告，是安装失败）。
    info["MinimumOSVersion"] = "17.0"
    info["CFBundleSupportedPlatforms"] = ["iPhoneOS"]
    info["DTPlatformName"] = "iphoneos"
    info["UIDeviceFamily"] = [1, 2]          # iPhone + iPad
    # 旧式图标声明：没有 Assets.car 时 SpringBoard 走这条路（见 make_unsigned_ipa.sh 头注）。
    info["CFBundleIcons"] = {
        "CFBundlePrimaryIcon": {
            "CFBundleIconFiles": ["AppIcon120", "AppIcon180"],
            "CFBundleIconName": "AppIcon",
        }
    }
    info["CFBundleIcons~ipad"] = info["CFBundleIcons"]

    with open(dst, "wb") as f:
        plistlib.dump(info, f)
    # 二进制 plist：与 Xcode 产物一致，也省点体积。
    subprocess.run(["plutil", "-convert", "binary1", dst], check=True)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])

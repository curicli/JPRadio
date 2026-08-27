#!/bin/zsh
# 把 app 的台表同步到 web 版：编译 Station.swift + tools/DumpStationsJSON.swift，
# 输出 web/public/stations.json。
#
# **为什么要编译而不是手抄**：116 条电台字面量只该有一份出处（ios/JPRadio/Models/Station.swift）。
# 手抄一份到 JSON 里，改完 app 忘了改 web（或反过来）是必然会发生的事。台表动过就跑一次这个。
#
# 用法：zsh web/sync-stations.sh
set -e

ROOT=${0:a:h:h}
cd "$ROOT"

DEV=/Applications/xcode.app/Contents/Developer
SWIFTC=$DEV/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
SDK=$DEV/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
OUT=${TMPDIR:-/tmp}/jpradio-dumpstations
JSON=web/public/stations.json

# 注意用的是 **MacOSX SDK**：这个小工具是在 Mac 上跑的命令行程序，不是 iOS target 的一部分
# （tools/ 整个目录都不在 PBXFileSystemSynchronizedRootGroup 里，不会被打进 app）。
"$SWIFTC" -sdk "$SDK" -O -module-cache-path "${TMPDIR:-/tmp}/mcache" -disable-sandbox \
  -o "$OUT" ios/JPRadio/Models/Station.swift tools/DumpStationsJSON.swift

"$OUT" > "$JSON.new"
mv "$JSON.new" "$JSON"

# 顺手自检一遍：台数/频率范围/直连台有没有流地址，都在 web/test/check.mjs 里钉着。
node web/test/check.mjs

python3 - "$JSON" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
stations = [s for r in doc["regions"] for s in r["stations"]]
print(f"{sys.argv[1]}：{len(doc['regions'])} 条拨盘 / {len(stations)} 台"
      f"（直连 {sum(1 for s in stations if s['direct'])}）")
PY

// 电台数据表的离线自测（在 Mac 上跑；在 JPRadio/ 之外，不进 iOS target）。
//
//   SWIFTC=/Applications/xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
//   SDK=/Applications/xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
//   "$SWIFTC" -sdk "$SDK" -o /tmp/stcheck JPRadio/Models/Station.swift Tools/StationDataCheck.swift
//   /tmp/stcheck
//
// 盯的是「拨盘上的频率必须是真实广播频率」这件事：曾经直连台用的是均匀假档位，
// 刻度尺上的读数于是与电台实际频率完全不符。这里用几条硬约束把那种回退挡住：
// 频率落在合法波段内、每个拨盘按频率升序、台名里自带频率的台必须自洽。
import Foundation

var failures = 0

func expect(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        print("✓ \(name)")
    } else {
        print("✗ \(name)\(detail().isEmpty ? "" : " — \(detail())")")
        failures += 1
    }
}

@main
struct StationDataCheck {
static func main() {

let all = Station.allStations

// 1. id 唯一（收藏/录音/预约都按 id 引用，重复会串台）。
let ids = Set(all.map(\.id))
expect("id 唯一", ids.count == all.count, "\(all.count) 台 / \(ids.count) 个 id")

// 2. 频率都在拨盘范围内。
let outOfRange = all.filter { $0.frequency < Station.dialLowerBound || $0.frequency > Station.dialUpperBound }
expect("频率都在拨盘范围内", outOfRange.isEmpty,
       outOfRange.map { "\($0.name) \($0.frequency)" }.joined(separator: ", "))

// 3. 每个地区按频率升序（拖刻度与滑卡片的方向必须一致）。
for region in Station.regions {
    let freqs = region.stations.map(\.frequency)
    expect("\(region.id) 按频率升序", freqs == freqs.sorted(), "\(freqs)")
}

// 4. 社区FM 台落在日本社区放送波段 76.1–89.9（否则说明填的又是假档位）。
let direct = all.filter(\.isDirect)
let offBand = direct.filter { $0.frequency < 76.1 || $0.frequency > 89.9 }
expect("直连台都在 76.1–89.9", offBand.isEmpty,
       offBand.map { "\($0.name) \($0.frequency)" }.joined(separator: ", "))
expect("直连台数量", direct.count == 77, "\(direct.count)")

// 5. 台名里自带频率的台必须自洽 —— 这几条是「频率是真的」最硬的证据。
let selfEvident: [(String, Double)] = [
    ("LR30026", 77.5),   // 775ライブリーFM
    ("LR30092", 80.1),   // なとらじ801
    ("LR30024", 81.5),   // FM815（高松）
    ("LR30071", 87.0),   // FM87.0 RADIO MIX KYOTO
    ("LR30010", 79.1),   // FMびざん（B-FM791）
]
for (id, freq) in selfEvident {
    let station = Station.station(id: id)
    expect("\(station?.name ?? id) = \(freq)", station?.frequency == freq,
           "\(station?.frequency.description ?? "nil")")
}

// 6. 直连台的流地址与台标都由 ChannelId 推出，别写歪。
for s in direct {
    let channel = s.id.dropFirst(2)   // "LR30008" → "30008"
    let okStream = s.directStreamURL == "https://mtist.as.smartstream.ne.jp/\(channel)/livestream/playlist.m3u8"
    let okLogo = s.logoOverride == "https://listenradio.jp/img/rslogo/\(channel)r.png"
    if !okStream || !okLogo {
        expect("\(s.name) 的流/台标地址", false, s.directStreamURL ?? "nil")
    }
}
expect("直连台地址规律一致", true)

// 7. radiko 台不应带直连地址（否则会绕过鉴权、放不出声）。
let radiko = all.filter { !$0.isDirect }
expect("radiko 台无 directStreamURL", radiko.allSatisfy { $0.directStreamURL == nil })
expect("radiko 台数量 > 0", !radiko.isEmpty, "\(radiko.count)")

// 8. 「全部」拨盘：所有台去重后按频率升序（拖刻度与滑卡片必须同向，见 FrequencyDialView）。
let dial = Station.allStationsByFrequency
expect("「全部」拨盘含全部电台", dial.count == Set(all.map(\.id)).count, "\(dial.count) / \(all.count)")
expect("「全部」拨盘 id 不重复", Set(dial.map(\.id)).count == dial.count)
expect("「全部」拨盘按频率升序",
       zip(dial, dial.dropFirst()).allSatisfy { $0.frequency <= $1.frequency },
       zip(dial, dial.dropFirst()).first { $0.frequency > $1.frequency }
        .map { "\($0.name) \($0.frequency) → \($1.name) \($1.frequency)" } ?? "")
// 同频台在这条尺子上必然重叠，次序不能靠 sorted 的运气 —— 并列时按 id 排，跨启动稳定。
expect("同频台次序确定（按 id）",
       zip(dial, dial.dropFirst()).allSatisfy {
           $0.frequency < $1.frequency || $0.id < $1.id
       })

print(failures == 0 ? "\n全部通过" : "\n\(failures) 项没过")
exit(failures == 0 ? 0 : 1)
}
}

// 把 Station.swift 里的电台/地区表导出成 web 版用的 JSON（在 Mac 上跑；不进 iOS target）。
//
//   SWIFTC=/Applications/xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
//   SDK=/Applications/xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
//   "$SWIFTC" -sdk "$SDK" -o "$TMPDIR/dumpstations" ios/JPRadio/Models/Station.swift tools/DumpStationsJSON.swift
//   "$TMPDIR/dumpstations" > web/public/stations.json
//
// **为什么要有这个东西**：web 版必须用与 app 完全一样的台表，手抄 116 条字面量迟早会漂。
// 这里直接编译 Station.swift 再打印，Station.swift 永远是唯一出处；台表改了就重跑一次
// （`zsh web/sync-stations.sh`）。
//
// 输出形状（拨盘顺序＝app 里 `Station.regions` 的顺序，合成拨盘★/ALL 由前端自己拼）：
//   { "dialLowerBound": 76.0, "dialUpperBound": 95.0,
//     "regions": [ { "id","name","subtitle","kind":"radiko"|"listenradio",
//                    "stations": [ { "id","name","frequency","areaID","tagline",
//                                    "direct":Bool,"streamURL":String?,"logo":String } ] } ] }
import Foundation

@main
struct DumpStationsJSON {
    static func main() {
        var regions: [[String: Any]] = []
        for region in Station.regions {
            let stations: [[String: Any]] = region.stations.map { s in
                var dict: [String: Any] = [
                    "id": s.id,
                    "name": s.name,
                    "frequency": s.frequency,
                    "areaID": s.areaID,
                    "tagline": s.tagline,
                    "direct": s.isDirect,
                    "logo": s.logoURL?.absoluteString ?? "",
                ]
                // 直连台（ListenRadio）的流地址要带给服务端做反代；radiko 台的流地址
                // 得先鉴权才知道，服务端自己去解析，这里没有这一项。
                if let url = s.directStreamURL { dict["streamURL"] = url }
                return dict
            }
            regions.append([
                "id": region.id,
                "name": region.name,
                "subtitle": region.subtitle,
                // 前端据此决定要不要显示 MHz、要不要给番組表按钮：radiko 与 ListenRadio
                // 的番組表是两套接口，而合成频率的直连台不该把假频率当真读数展示。
                "kind": region.stations.first?.isDirect == true ? "listenradio" : "radiko",
                "stations": stations,
            ])
        }

        let root: [String: Any] = [
            "dialLowerBound": Station.dialLowerBound,
            "dialUpperBound": Station.dialUpperBound,
            "regions": regions,
        ]

        guard let data = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else {
            FileHandle.standardError.write(Data("JSON 序列化失败\n".utf8))
            exit(1)
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

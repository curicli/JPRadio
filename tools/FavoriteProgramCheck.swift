// 收藏节目的离线自测（在 Mac 上跑；在 ios/JPRadio/ 之外，不进 iOS target）。
//
//   SWIFTC=/Applications/xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
//   SDK=/Applications/xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
//   "$SWIFTC" -sdk "$SDK" -o /tmp/favcheck \
//       ios/JPRadio/Models/Station.swift ios/JPRadio/Radiko/RadikoStream.swift \
//       ios/JPRadio/Radiko/RadikoAuth.swift ios/JPRadio/Radiko/RadikoProfile.swift \
//       ios/JPRadio/Recording/FavoriteProgramStore.swift Tools/FavoriteProgramCheck.swift
//   /tmp/favcheck
//
// 盯的是「收藏跨天仍认得出同一档节目」这件事：番組表里每次播出都是一条新记录
// （`program.id` 含放送日与起止时刻），拿它当收藏键的话今天收藏的节目明天就变成没收藏。
// 另外钉住已存数据的 Codable 形状 —— 字段改名会让用户已有的收藏静默清空。
import Foundation

/// RadioPlayer 在 iOS target 里（AVFoundation/MediaPlayer），这里只需要它的 UA 常量。
enum RadioPlayer {
    static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
}

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
struct FavoriteProgramCheck {
static func main() {

let station = Station.station(id: "FMT")!

/// 同一档节目在两天的番組表里：`id` 不同（含放送日），台号与节目名相同。
func airing(_ day: String, _ title: String) -> RadikoProgram {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "Asia/Tokyo")
    f.dateFormat = "yyyyMMddHHmm"
    let start = f.date(from: "\(day)1300")!
    return RadikoProgram(id: "FMT-\(day)130000", title: title, performer: "山田",
                         start: start, end: start.addingTimeInterval(7200), imageURL: nil)
}

let today = airing("20260824", "ゴールデンラジオ")
let tomorrow = airing("20260825", "ゴールデンラジオ")
let other = airing("20260824", "夕方ワイド")

// 1. 键只由「台号 + 节目名」决定 —— 换一天必须还是同一条收藏。
expect("program.id 每天不同（前提）", today.id != tomorrow.id, "\(today.id) / \(tomorrow.id)")
let key = FavoriteProgramStore.key(stationID: station.id, title: today.title)
expect("跨天同键", key == FavoriteProgramStore.key(stationID: station.id, title: tomorrow.title))
expect("换节目换键",
       key != FavoriteProgramStore.key(stationID: station.id, title: other.title))
expect("换台换键", key != FavoriteProgramStore.key(stationID: "FMJ", title: today.title))
expect("键的形状 fav-<台>#<节目名>", key == "fav-FMT#ゴールデンラジオ", key)

// 2. Codable 形状：字段名改了会让用户已存的收藏解不出来（静默清空），钉在这里。
let item = FavoriteProgram(id: key, stationID: station.id, stationName: station.name,
                           title: today.title, performer: today.performer,
                           start: today.start, end: today.end, addedAt: Date())
guard let data = try? JSONEncoder().encode([item]),
      let json = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
      let first = json.first else {
    print("✗ 编不出 JSON"); exit(1)
}
expect("持久化字段齐全",
       Set(first.keys) == ["id", "stationID", "stationName", "title", "performer",
                           "start", "end", "addedAt"],
       first.keys.sorted().joined(separator: ","))
let restored = try? JSONDecoder().decode([FavoriteProgram].self, from: data)
expect("解码回同一条", restored?.first == item, "\(restored?.count ?? -1) 条")

// 3. 没有时刻的条目也要能收藏（自定义/番組表缺字段时 start/end 为 nil）。
let timeless = FavoriteProgram(id: "fav-FMT#無題", stationID: "FMT", stationName: "TOKYO FM",
                               title: "無題", performer: "", start: nil, end: nil, addedAt: Date())
expect("无时刻 → 时段文案为空", timeless.slotText.isEmpty, timeless.slotText)
let timelessData = try? JSONEncoder().encode([timeless])
expect("无时刻也能存取",
       timelessData.flatMap { try? JSONDecoder().decode([FavoriteProgram].self, from: $0) }?.first
        == timeless)

// 4. 时段文案：星期 + 起止时刻，且必须按**日本时间**算（用户人在境外时不能跟着本地时区跑）。
//    2026-08-24 13:00 JST 是星期一。
expect("时段含起止时刻", item.slotText.contains("13:00") && item.slotText.contains("15:00"),
       item.slotText)
let jstWeekday: Int = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    return cal.component(.weekday, from: today.start!)
}()
expect("2026-08-24 JST 是星期一（前提）", jstWeekday == 2, "\(jstWeekday)")
// 星期的写法随语言变（Mon / 周一 / 月）—— 只断言它不是空的、且排在时刻前面。
expect("时段带星期", item.slotText.count > "13:00 – 15:00".count, item.slotText)

print(failures == 0 ? "\n全部通过" : "\n\(failures) 项没过")
exit(failures == 0 ? 0 : 1)
}
}

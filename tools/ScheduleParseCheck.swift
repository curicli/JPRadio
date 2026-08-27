// ListenRadio 番組表解析的离线自测（在 Mac 上跑；在 ios/JPRadio/ 之外，不进 iOS target）。
//
//   SWIFTC=/Applications/xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
//   SDK=/Applications/xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
//   "$SWIFTC" -sdk "$SDK" -O -o /tmp/schedcheck \
//       ios/JPRadio/Models/Station.swift ios/JPRadio/Radiko/RadikoStream.swift \
//       ios/JPRadio/Radiko/RadikoAuth.swift ios/JPRadio/Radiko/RadikoProfile.swift \
//       ios/JPRadio/ListenRadio/ScheduleJSON.swift ios/JPRadio/ListenRadio/ListenRadioProgramService.swift \
//       Tools/ScheduleParseCheck.swift
//   /tmp/schedcheck
//
// 样本 11 是**用机上诊断报告确认的真实形状**（ProgramList → Schedule，12 位 yyyyMMddHHmm）；
// 其余样本用**多种可能的返回形状**验证「不依赖键名/结构」这套解析是否顶得住：键名大小写与命名法、
// 完整时间戳 / 纯时刻 + 日期字段 / epoch 毫秒 / .NET Date() / yyyyMMddHHmm(ss)、
// 平铺数组 / 包一层 / 按日分组。
import Foundation

/// RadioPlayer 在 iOS target 里（AVFoundation/MediaPlayer），这里只需要它的 UA 常量。
enum RadioPlayer {
    static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
}

let jstCal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    return c
}()

func fmt(_ pattern: String, _ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "Asia/Tokyo")
    f.dateFormat = pattern
    return f.string(from: date)
}

/// 今天的放送日起点（JST 05:00），所有样本都围绕它构造，免得跟真实「今天」错开。
let day0 = ListenRadioProgramService.broadcastDayStart(dayOffset: 0)
let ymdDash = fmt("yyyy-MM-dd", day0)
let ymdSlash = fmt("yyyy/MM/dd", day0)
let ymd = fmt("yyyyMMdd", day0)

func epochMS(_ hour: Int, _ minute: Int = 0) -> Int {
    var comps = jstCal.dateComponents([.year, .month, .day], from: day0)
    comps.hour = hour; comps.minute = minute
    return Int(jstCal.date(from: comps)!.timeIntervalSince1970 * 1000)
}

var failures = 0

/// 跑一个样本：期望解析出 `expected` 档节目，且第一档的起点是 JST `firstHour:firstMinute`。
func check(_ name: String, _ json: String, expected: Int, firstHour: Int, firstMinute: Int = 0) {
    guard let data = json.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) else {
        print("✗ \(name): 样本本身不是合法 JSON"); failures += 1; return
    }
    let rows = ScheduleJSON.rows(in: root)
    let programs = ScheduleJSON.programs(from: rows, channel: "30008")
    let day = programs.filter { p in
        guard let s = p.start else { return false }
        return s >= day0 && s < day0.addingTimeInterval(24 * 3600)
    }
    var problems: [String] = []
    if day.count != expected { problems.append("day0 节目数 \(day.count) ≠ \(expected)") }
    if let first = day.first {
        let h = jstCal.component(.hour, from: first.start!)
        let m = jstCal.component(.minute, from: first.start!)
        if h != firstHour || m != firstMinute {
            problems.append(String(format: "首档 %02d:%02d ≠ %02d:%02d", h, m, firstHour, firstMinute))
        }
        if first.end == nil { problems.append("首档没有结束时间") }
        if first.title.isEmpty || first.title == T.noProgramTitle { problems.append("首档没标题") }
    } else {
        problems.append("day0 一档都没有")
    }
    if problems.isEmpty {
        let first = day.first!
        print("✓ \(name): rows=\(rows.count) programs=\(programs.count) day0=\(day.count) "
              + "首档 \(fmt("MM/dd HH:mm", first.start!))–\(fmt("HH:mm", first.end!)) 「\(first.title)」")
    } else {
        print("✗ \(name): rows=\(rows.count) programs=\(programs.count) — \(problems.joined(separator: "；"))")
        if let f = day.first {
            print("    首档 = \(fmt("MM/dd HH:mm", f.start!)) 「\(f.title)」")
        }
        failures += 1
    }
}

// 1. PascalCase 平铺数组 + 日期字段 + 纯时刻（最像 ASP.NET 接口的形状）
@main
struct ScheduleParseCheck {
static func main() {
check("PascalCase + 日期 + HH:mm", """
[
 {"ChannelId":30008,"ProgramTitle":"モーニングフラッグ","PersonalityName":"山田","OnAirDate":"\(ymdDash)","OnAirStartTime":"07:00","OnAirEndTime":"09:00"},
 {"ChannelId":30008,"ProgramTitle":"デイタイム","PersonalityName":"佐藤","OnAirDate":"\(ymdDash)","OnAirStartTime":"09:00","OnAirEndTime":"12:00"},
 {"ChannelId":30008,"ProgramTitle":"ミッドナイト","PersonalityName":"","OnAirDate":"\(ymdDash)","OnAirStartTime":"23:30","OnAirEndTime":"01:00"}
]
""", expected: 3, firstHour: 7)

// 2. 包一层 + 完整时间戳（yyyy/MM/dd HH:mm:ss）
check("包一层 + 完整时间戳", """
{"Result":0,"Message":"OK","ScheduleList":[
 {"ScheduleId":1,"ScheduleTitle":"朝の音楽","ScheduleDetail":"洋楽","StartDateTime":"\(ymdSlash) 06:00:00","EndDateTime":"\(ymdSlash) 08:00:00"},
 {"ScheduleId":2,"ScheduleTitle":"昼の音楽","ScheduleDetail":"邦楽","StartDateTime":"\(ymdSlash) 08:00:00","EndDateTime":"\(ymdSlash) 10:00:00"}
]}
""", expected: 2, firstHour: 6)

// 3. epoch 毫秒（数值）
check("epoch 毫秒", """
{"data":{"programs":[
 {"id":11,"name":"Night Cruise","start":\(epochMS(22)),"end":\(epochMS(23, 30))},
 {"id":12,"name":"Late Show","start":\(epochMS(23, 30)),"end":\(epochMS(25))}
]}}
""", expected: 2, firstHour: 22)

// 4. .NET 的 /Date(...)/
check(".NET /Date()/", """
[
 {"Title":"Sunrise","Start":"/Date(\(epochMS(5, 30))+0900)/","End":"/Date(\(epochMS(7))+0900)/"},
 {"Title":"Commute","Start":"/Date(\(epochMS(7))+0900)/","End":"/Date(\(epochMS(9))+0900)/"}
]
""", expected: 2, firstHour: 5, firstMinute: 30)

// 5. yyyyMMddHHmmss（radiko 风格；若先当 epoch 会跑到 26 世纪）
check("yyyyMMddHHmmss", """
{"prog":[
 {"title":"Afternoon Beat","ft":"\(ymd)130000","to":"\(ymd)150000","pfm":"DJ Ken"},
 {"title":"Evening Beat","ft":"\(ymd)150000","to":"\(ymd)170000","pfm":"DJ Rin"}
]}
""", expected: 2, firstHour: 13)

// 6. 按放送日分组（今天 + 明天各一组）：合并后今天应只剩今天那两档
check("按日分组", """
{"days":[
 {"date":"\(ymdDash)","list":[
   {"ProgramName":"Group A1","OnairStartTime":"\(ymdDash) 10:00","OnairEndTime":"\(ymdDash) 11:00"},
   {"ProgramName":"Group A2","OnairStartTime":"\(ymdDash) 11:00","OnairEndTime":"\(ymdDash) 12:00"}]},
 {"date":"\(fmt("yyyy-MM-dd", day0.addingTimeInterval(86400)))","list":[
   {"ProgramName":"Group B1","OnairStartTime":"\(fmt("yyyy-MM-dd", day0.addingTimeInterval(86400))) 10:00","OnairEndTime":"\(fmt("yyyy-MM-dd", day0.addingTimeInterval(86400))) 11:00"}]}
]}
""", expected: 2, firstHour: 10)

// 7. 只有一个时刻字段（没有结束时间）：应该用下一档的起点补
check("只有开始时间", """
[
 {"title":"Slot 1","time":"\(ymdDash) 14:00"},
 {"title":"Slot 2","time":"\(ymdDash) 15:00"},
 {"title":"Slot 3","time":"\(ymdDash) 16:00"}
]
""", expected: 3, firstHour: 14)

// 8. 键名全不认识（英文小写下划线 + ISO8601 带时区）
check("snake_case + ISO8601", """
{"schedule":[
 {"program_subject":"Indie Hour","broadcast_from":"\(ymdDash)T18:00:00+09:00","broadcast_until":"\(ymdDash)T19:00:00+09:00"},
 {"program_subject":"Jazz Hour","broadcast_from":"\(ymdDash)T19:00:00+09:00","broadcast_until":"\(ymdDash)T20:00:00+09:00"}
]}
""", expected: 2, firstHour: 18)

// 9. 放送日只写在外层分组上，行里只有 HH:mm（没有继承日期的话，明天的节目会挤到今天）
let tomorrow = fmt("yyyy-MM-dd", day0.addingTimeInterval(86400))
check("外层日期 + 行内 HH:mm", """
{"ScheduleList":[
 {"OnAirDate":"\(ymdDash)","Programs":[
   {"ProgramTitle":"Today 10","StartTime":"10:00","EndTime":"11:00"},
   {"ProgramTitle":"Today 11","StartTime":"11:00","EndTime":"12:00"}]},
 {"OnAirDate":"\(tomorrow)","Programs":[
   {"ProgramTitle":"Tomorrow 12","StartTime":"12:00","EndTime":"13:00"}]}
]}
""", expected: 2, firstHour: 10)

// 10. 行里连日期都没有（整张表就是今天）：退回今天的放送日锚定
check("纯 HH:mm 无日期", """
[
 {"ProgramName":"Morning","Start":"06:30","End":"08:00"},
 {"ProgramName":"Noon","Start":"12:00","End":"13:00"},
 {"ProgramName":"After midnight","Start":"01:00","End":"02:00"}
]
""", expected: 3, firstHour: 6, firstMinute: 30)

// 11. **真实形状**（2026-08-24 用机上的诊断报告，FM Kawaguchi / channelId=30035）：
//     ProgramList → 频道字典 → Schedule，时刻是 12 位的 yyyyMMddHHmm（没有秒）。
//     这条曾经解析出 0 行 —— DateFormatter 要求整串匹配，格式表里只有 14 位那条。
check("真实形状 ProgramList/Schedule + yyyyMMddHHmm", """
{"Result":0,"ServerTime":"\(fmt("yyyy-MM-dd'T'HH:mm:ss.SSSSSSS", day0))+09:00","ViewChannelId":30035,"ProgramList":[
 {"ChannelId":30035,"ChannelName":"FM Kawaguchi","ChannelDetail":"埼玉県川口市にあるコミュニティFMラジオ局です。","ChannelLogo":"http:\\/\\/listenradio.jp\\/img\\/rslogo\\/30035r.png","ChannelType":2,"Schedule":[
  {"ProgramId":18585753,"ProgramName":"サイマル放送休止中","ProgramSummary":"-","StartDate":"\(ymd)0000","EndDate":"\(ymd)0600","MainteFlg":true,"Timetable":[],"FeatureUrl":"","BackupMode":0},
  {"ProgramId":18585755,"ProgramName":"シティウォーキン","ProgramSummary":"洋楽邦楽・新譜旧譜を織り混ぜてのミュージックセレクション。","StartDate":"\(ymd)0700","EndDate":"\(ymd)0900","MainteFlg":false,"Timetable":[],"FeatureUrl":"","BackupMode":0},
  {"ProgramId":18585756,"ProgramName":"Class Up Kawaguchi","ProgramSummary":"毎日の暮らしを少しUPさせる楽しい情報を紹介。","StartDate":"\(ymd)0900","EndDate":"\(ymd)0920","MainteFlg":false,"Timetable":[],"FeatureUrl":"","BackupMode":0},
  {"ProgramId":18585757,"ProgramName":"シティウォーキン","ProgramSummary":"-","StartDate":"\(ymd)0920","EndDate":"\(ymd)1000","MainteFlg":false,"Timetable":[],"FeatureUrl":"","BackupMode":0}
 ]}
]}
""", expected: 3, firstHour: 7)

// 12. 12 位与 14 位混在一张表里也都要认（长的那条不能被短的截着解析）。
check("12 位与 14 位混排", """
{"Schedule":[
 {"ProgramName":"Twelve","StartDate":"\(ymd)1600","EndDate":"\(ymd)1700"},
 {"ProgramName":"Fourteen","StartDate":"\(ymd)170000","EndDate":"\(ymd)180000"}
]}
""", expected: 2, firstHour: 16)

print(failures == 0 ? "\n全部通过" : "\n\(failures) 个样本没过")
exit(failures == 0 ? 0 : 1)
}
}

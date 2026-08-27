// HLS 播放列表解析的离线自测（在 Mac 上跑；在 ios/JPRadio/ 之外，不进 iOS target）。
//
//   SWIFTC=/Applications/xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
//   SDK=/Applications/xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
//   "$SWIFTC" -sdk "$SDK" -o /tmp/plcheck \
//       ios/JPRadio/Models/Station.swift ios/JPRadio/Radiko/RadikoStream.swift ios/JPRadio/Radiko/RadikoAuth.swift \
//       ios/JPRadio/Radiko/RadikoProfile.swift ios/JPRadio/Recording/RadioRecorder.swift \
//       Tools/PlaylistParseCheck.swift
//   /tmp/plcheck
//
// 盯的是内源识曲那条链路的入口：`#EXTINF` 时长要与分片一一对应（否则「往回取十几秒」
// 会取错片数），master 里的 chunklist 不能被当成音频分片，以及 tailCount 的边界。
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

let base = URL(string: "https://example.com/hls/ch1/chunklist.m3u8")!

@main
struct PlaylistParseCheck {
static func main() {

// 1. 常规直播 chunklist：分片与时长一一对应。
let live = """
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:5
#EXT-X-MEDIA-SEQUENCE:1200
#EXTINF:5.005,
seg1200.aac
#EXTINF:4.998,
seg1201.aac
#EXTINF:5.000,
seg1202.aac
"""
let pl = HLSRecorderKit.parse(live, base: base)
expect("直播 chunklist：3 片", pl.segments.count == 3, "得到 \(pl.segments.count)")
expect("时长与分片一一对应", pl.durations.count == pl.segments.count,
       "durations=\(pl.durations.count) segments=\(pl.segments.count)")
expect("时长解析正确", pl.durations.first == 5.005 && pl.durations.last == 5.0, "\(pl.durations)")
expect("media-sequence", pl.mediaSequence == 1200, "\(pl.mediaSequence)")
expect("相对路径展开", pl.segments.first?.absoluteString == "https://example.com/hls/ch1/seg1200.aac",
       pl.segments.first?.absoluteString ?? "nil")

// 2. master：带查询参数的 chunklist 不能被当成分片（否则会把 m3u8 文本当音频）。
let master = """
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=51200,CODECS="mp4a.40.5"
https://cdn.example.com/tf/chunklist?station_id=FMT&seek=20260824120000&l=300
"""
let mpl = HLSRecorderKit.parse(master, base: base)
expect("master：0 片 / 1 子列表", mpl.segments.isEmpty && mpl.subPlaylists.count == 1,
       "segments=\(mpl.segments.count) subs=\(mpl.subPlaylists.count)")

// 3. fMP4：init 段 + ENDLIST。
let fmp4 = """
#EXTM3U
#EXT-X-MAP:URI="init.mp4"
#EXTINF:6.0,
seg1.m4s
#EXT-X-ENDLIST
"""
let fpl = HLSRecorderKit.parse(fmp4, base: base)
expect("fMP4：认出 init 段", fpl.initSegment?.lastPathComponent == "init.mp4",
       fpl.initSegment?.absoluteString ?? "nil")
expect("fMP4：ENDLIST + 1 片", fpl.isEndlist && fpl.segments.count == 1,
       "endlist=\(fpl.isEndlist) segments=\(fpl.segments.count)")

// 4. 没有 EXTINF 的列表（靠扩展名启发式）：时长补 0，但数量仍要对齐。
let noInf = """
#EXTM3U
seg1.aac
seg2.aac
"""
let npl = HLSRecorderKit.parse(noInf, base: base)
expect("无 EXTINF：数量仍对齐", npl.segments.count == 2 && npl.durations == [0, 0],
       "segments=\(npl.segments.count) durations=\(npl.durations)")

// 5. tailCount：往回取够 12 秒。
expect("tailCount 5s×N → 12s 取 3 片",
       HLSRecorderKit.tailCount(durations: [5, 5, 5, 5, 5], seconds: 12) == 3,
       "\(HLSRecorderKit.tailCount(durations: [5, 5, 5, 5, 5], seconds: 12))")
expect("tailCount 长分片一片就够",
       HLSRecorderKit.tailCount(durations: [10, 10, 30], seconds: 12) == 1,
       "\(HLSRecorderKit.tailCount(durations: [10, 10, 30], seconds: 12))")
expect("tailCount 不够时取全部",
       HLSRecorderKit.tailCount(durations: [4, 4], seconds: 12) == 2,
       "\(HLSRecorderKit.tailCount(durations: [4, 4], seconds: 12))")
expect("tailCount 时长缺失按 5s 估",
       HLSRecorderKit.tailCount(durations: [0, 0, 0, 0], seconds: 12) == 3,
       "\(HLSRecorderKit.tailCount(durations: [0, 0, 0, 0], seconds: 12))")
expect("tailCount 空列表为 0", HLSRecorderKit.tailCount(durations: [], seconds: 12) == 0)

// 6. 分片嗅探：m3u8 文本绝不能被当成音频。
expect("嗅探：ADTS", SegmentWriter.sniff(Data([0xFF, 0xF1, 0x50, 0x80])) == .adts)
expect("嗅探：MPEG-TS", SegmentWriter.sniff(Data([0x47] + [UInt8](repeating: 0, count: 187) + [0x47])) == .mpegTS)
expect("嗅探：fMP4", SegmentWriter.sniff(Data([0x00, 0x00, 0x00, 0x18] + Array("ftypiso5".utf8))) == .fragmentedMP4)

print(failures == 0 ? "\n全部通过" : "\n\(failures) 项没过")
exit(failures == 0 ? 0 : 1)
}
}

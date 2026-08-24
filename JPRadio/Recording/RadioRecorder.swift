import Foundation
import AVFoundation

/// 录制/下载失败的原因，**带上出错的环节与 HTTP 状态**。
///
/// timefree 抓取链路长（鉴权 → stream XML → playlist → chunklist → 分片），
/// 早先每一步都用 `try?` 吞掉，任何一环坏了都只表现为「没有音频」，无从判断。
/// 这里让每个环节都能自证死因，并把它显示在预约行上。
enum RecordingError: LocalizedError {
    case http(stage: String, status: Int)
    case network(stage: String, detail: String)
    case tokenExpired
    /// 播放列表拿到了，但里面一个分片都没有（多数是时间参数不对或该段没有存档）。
    case noSegments(windows: Int)
    /// 分片全部下载失败。
    case allSegmentsFailed(tried: Int)
    /// 分片下到了，但写出来是空文件（封装嗅探/解包失败）。
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .http(let stage, let status):    return "\(stage) HTTP \(status)"
        case .network(let stage, let detail): return "\(stage): \(detail)"
        case .tokenExpired:                   return "auth token expired"
        case .noSegments(let windows):        return "no segments in \(windows) playlist window(s)"
        case .allSegmentsFailed(let tried):   return "all \(tried) segment(s) failed to download"
        case .emptyOutput:                    return "downloaded data contained no audio"
        }
    }
}

/// HLS 分片下载与拼接的公用工具。
///
/// 关键：**不能无脑拼接分片**。HLS 音频分片有三种常见封装，拼出来能直接播的只有第一种：
/// - 裸 ADTS AAC（radiko タイムフリー）→ 顺序拼接即可。
/// - MPEG-TS（多数社区FM / 部分 radiko 直播）→ 必须先从 TS 里抽出音频基本流，
///   否则拼出来的文件 AVPlayer / 系统播放器都打不开（就是「完全是无效文件」）。
/// - fMP4（`#EXT-X-MAP`）→ 写 init 段 + 后续分片，扩展名用 `.m4a`。
enum HLSRecorderKit {

    struct Playlist {
        var mediaSequence = 0
        var initSegment: URL?        // #EXT-X-MAP:URI=
        var subPlaylists: [URL] = [] // 指向 chunklist 的 .m3u8（master 情形）
        var segments: [URL] = []     // 媒体分片
        /// 与 `segments` 一一对应的 `#EXTINF` 时长（秒）；缺标签时为 0。
        /// 识曲只需要最近十几秒，靠它才能知道「往回数几个分片就够」。
        var durations: [Double] = []
        var isEndlist = false        // #EXT-X-ENDLIST
    }

    /// 解析一段 m3u8 文本，相对 URL 以 `base` 展开为绝对地址。
    ///
    /// 「是子播放列表还是媒体分片」按**前一行的标签**判定（`#EXT-X-STREAM-INF` → 子列表，
    /// `#EXTINF` → 分片），而不是看扩展名：radiko タイムフリー 的 master 里那行 chunklist
    /// 带一长串查询参数，靠 `.m3u8` 猜会被误当成音频分片下载，结果拼出来的「录音」
    /// 其实是一段 m3u8 文本。没有标签时才退回扩展名启发式。
    static func parse(_ text: String, base: URL) -> Playlist {
        var p = Playlist()
        var pendingKind: Kind?
        var pendingDuration: Double?
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                    p.mediaSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
                } else if line.hasPrefix("#EXT-X-MAP:") {
                    if let uri = attribute("URI", in: line), let u = URL(string: uri, relativeTo: base) {
                        p.initSegment = u.absoluteURL
                    }
                } else if line.hasPrefix("#EXT-X-STREAM-INF") {
                    pendingKind = .subPlaylist
                } else if line.hasPrefix("#EXTINF") {
                    pendingKind = .segment
                    // "#EXTINF:5.0,title" → 5.0
                    let value = line.dropFirst("#EXTINF:".count).prefix { $0 != "," }
                    pendingDuration = Double(value.trimmingCharacters(in: .whitespaces))
                } else if line.hasPrefix("#EXT-X-ENDLIST") {
                    p.isEndlist = true
                }
                continue
            }
            guard let u = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
            let kind = pendingKind
                ?? (u.path.lowercased().hasSuffix(".m3u8") ? .subPlaylist : .segment)
            switch kind {
            case .subPlaylist: p.subPlaylists.append(u)
            case .segment:
                p.segments.append(u)
                p.durations.append(pendingDuration ?? 0)
            }
            pendingKind = nil
            pendingDuration = nil
        }
        return p
    }

    private enum Kind { case subPlaylist, segment }

    /// 「从播放列表末尾往回取几个分片才够 `seconds` 秒」。
    /// 缺 `#EXTINF` 时按 `assumed` 秒一片估；至少取 1 个，最多取全部。
    static func tailCount(durations: [Double], seconds: Double, assumed: Double = 5) -> Int {
        guard !durations.isEmpty else { return 0 }
        var take = 0
        var total = 0.0
        for d in durations.reversed() {
            take += 1
            total += d > 0 ? d : assumed
            if total >= seconds { break }
        }
        return take
    }

    /// 从 `KEY=value` 或 `KEY="value"` 里取属性值。
    static func attribute(_ name: String, in line: String) -> String? {
        guard let r = line.range(of: "\(name)=") else { return nil }
        var rest = Substring(line[r.upperBound...])
        if rest.first == "\"" {
            rest = rest.dropFirst()
            if let end = rest.firstIndex(of: "\"") { return String(rest[..<end]) }
        } else if let end = rest.firstIndex(of: ",") {
            return String(rest[..<end])
        }
        return String(rest)
    }

    // MARK: - HTTP 小工具

    static func makeSession(timeout: TimeInterval) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }

    static func getData(_ url: URL, headers: [String: String] = [:],
                        session: URLSession, stage: String) async throws -> Data {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            if error is CancellationError { throw error }
            throw RecordingError.network(stage: stage, detail: (error as NSError).localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw RecordingError.network(stage: stage, detail: "no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RecordingError.http(stage: stage, status: http.statusCode)
        }
        return data
    }

    static func getText(_ url: URL, headers: [String: String] = [:],
                        session: URLSession, stage: String) async throws -> String {
        let text = String(decoding: try await getData(url, headers: headers, session: session, stage: stage),
                          as: UTF8.self)
        // radiko 在 token 失效时返回 200 + 正文 "expired"，不看正文就会当成空播放列表。
        if text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "expired" {
            throw RecordingError.tokenExpired
        }
        return text
    }

    /// 下载一个分片：先按给定头请求，失败再退回无头请求（radiko timefree 的分片不认头，
    /// 而部分 CDN 反过来要求头）—— 两种都试一次，避免整段录音变成空文件。
    static func fetchSegment(_ url: URL, headers: [String: String],
                             session: URLSession) async -> Data? {
        if let d = try? await getData(url, headers: headers, session: session, stage: "segment") { return d }
        if !headers.isEmpty,
           let d = try? await getData(url, headers: [:], session: session, stage: "segment") { return d }
        return nil
    }

    /// 一个 URL 抓下来到底是分片还是又一层播放列表 —— **看正文，不看扩展名**。
    /// radiko 的 chunklist 地址带一长串查询参数，靠扩展名猜就会把一段 m3u8 文本
    /// 当成音频写进录音文件里（听起来「完全是无效文件」，其实里面是文本）。
    enum Node {
        case playlist(String)
        case media(Data)
    }

    static func fetchNode(_ url: URL, headers: [String: String],
                          session: URLSession) async -> Node? {
        guard let data = await fetchSegment(url, headers: headers, session: session) else { return nil }
        if data.prefix(7).elementsEqual(Array("#EXTM3U".utf8)) {
            return .playlist(String(decoding: data, as: UTF8.self))
        }
        return .media(data)
    }

    /// JST `yyyyMMddHHmmss` 时间戳（radiko timefree 参数格式）。
    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = "yyyyMMddHHmmss"
        return f
    }()
}

// MARK: - 分片写入器（封装嗅探 + TS 解包 + 落盘）

/// 把一串 HLS 分片写成**一个能直接播放**的音频文件。
/// 扩展名在写入第一个分片时按实际封装决定，文件也在那一刻才创建
/// （所以「一个字节都没下到」时不会留下空壳文件）。
final class SegmentWriter {

    enum Container {
        case adts       // 裸 AAC（ADTS）
        case mpegTS     // MPEG-TS，需抽出音频基本流
        case fragmentedMP4
        case mpeg1Audio // MP3
        case unknown

        /// 落盘后的扩展名。TS 抽流后就是 ADTS，故同为 aac。
        var fileExtension: String {
            switch self {
            case .adts, .mpegTS: return "aac"
            case .fragmentedMP4: return "m4a"
            case .mpeg1Audio:    return "mp3"
            case .unknown:       return "aac"
            }
        }
    }

    private let directory: URL
    private let baseName: String
    private var handle: FileHandle?
    private(set) var fileURL: URL?
    private(set) var container: Container?
    private(set) var bytesWritten = 0

    init(directory: URL, baseName: String) {
        self.directory = directory
        self.baseName = baseName
    }

    /// 追加一个分片。返回是否真的写进了字节。
    @discardableResult
    func append(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        // 最后一道防线：m3u8 文本绝不能被当成音频写进录音文件。
        guard !data.prefix(7).elementsEqual(Array("#EXTM3U".utf8)) else { return false }
        let kind = container ?? Self.sniff(data)
        let payload = (kind == .mpegTS) ? Self.audioStream(fromTS: data) : data
        guard !payload.isEmpty else { return false }

        if handle == nil {
            container = kind
            let url = directory.appendingPathComponent("\(baseName).\(kind.fileExtension)")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            guard let h = try? FileHandle(forWritingTo: url) else { return false }
            handle = h
            fileURL = url
        }
        handle?.write(payload)
        bytesWritten += payload.count
        return true
    }

    /// 收尾：有内容则返回文件，否则清理并返回 nil。
    func finish() -> URL? {
        try? handle?.close()
        handle = nil
        guard let fileURL, bytesWritten > 0 else {
            if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
            return nil
        }
        return fileURL
    }

    // MARK: - 封装嗅探

    static func sniff(_ data: Data) -> Container {
        let b = [UInt8](data.prefix(16))
        guard b.count >= 4 else { return .unknown }
        // MPEG-TS：同步字节 0x47，且第二个包首也对得上（188 字节栅格）。
        if b[0] == 0x47 {
            if data.count > 188 {
                let next = data[data.startIndex + 188]
                if next == 0x47 { return .mpegTS }
            } else {
                return .mpegTS
            }
        }
        // ADTS：12 位同步字 0xFFF。
        if b[0] == 0xFF, (b[1] & 0xF6) == 0xF0 { return .adts }
        // MP3：ID3 头或 0xFFE 同步字。
        if b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 { return .mpeg1Audio }
        if b[0] == 0xFF, (b[1] & 0xE0) == 0xE0 { return .mpeg1Audio }
        // ISO-BMFF：ftyp / styp / moof / sidx。
        if b.count >= 8 {
            let box = String(decoding: b[4..<8], as: UTF8.self)
            if ["ftyp", "styp", "moof", "sidx"].contains(box) { return .fragmentedMP4 }
        }
        return .unknown
    }

    // MARK: - MPEG-TS → 音频基本流

    /// 从 MPEG-TS 里抽出音频 PES 载荷（即 ADTS AAC 码流）。
    ///
    /// 不解 PAT/PMT：广播流只有一路音频，直接认 PES 的 `stream_id` 在 0xC0…0xDF
    /// 区间（MPEG audio）来锁定音频 PID，足够且更抗畸变。
    static func audioStream(fromTS data: Data) -> Data {
        let bytes = [UInt8](data)
        var out = Data(capacity: bytes.count / 2)
        var audioPID: Int? = nil
        var i = 0

        while i + 188 <= bytes.count {
            guard bytes[i] == 0x47 else { i += 1; continue }   // 重新同步
            let pusi = (bytes[i + 1] & 0x40) != 0
            let pid = (Int(bytes[i + 1] & 0x1F) << 8) | Int(bytes[i + 2])
            let afc = (bytes[i + 3] >> 4) & 0x03

            var payloadStart = i + 4
            if afc == 2 || afc == 3 {
                let afLength = Int(bytes[i + 4])
                payloadStart = i + 5 + afLength
            }
            // afc == 0（保留）/ 2（只有适配字段）没有载荷。
            guard afc == 1 || afc == 3, payloadStart < i + 188 else { i += 188; continue }

            if pusi {
                let p = payloadStart
                // PES 起始码 00 00 01 + stream_id
                if p + 9 <= i + 188, bytes[p] == 0x00, bytes[p + 1] == 0x00, bytes[p + 2] == 0x01 {
                    let streamID = bytes[p + 3]
                    if (0xC0...0xDF).contains(streamID) {
                        audioPID = pid
                        let headerLength = Int(bytes[p + 8])
                        let esStart = p + 9 + headerLength
                        if esStart < i + 188 {
                            out.append(contentsOf: bytes[esStart..<(i + 188)])
                        }
                    }
                }
            } else if let audioPID, pid == audioPID {
                out.append(contentsOf: bytes[payloadStart..<(i + 188)])
            }
            i += 188
        }
        return out
    }
}

// MARK: - タイムフリー 下载（预约/补录用，可靠）

enum TimefreeRecorder {
    /// 下载 [start, end) 这段时间的完整 timefree 录音，拼接为 `directory` 下一个音频文件。
    ///
    /// 复刻 rajiko `modules/timeshift.js` 的三段式，**每段的请求头都不一样**——
    /// 早先版本给 chunklist 和分片也带上了 radiko 头，CDN 直接 403，于是一段音频都拿不到：
    ///   1. playlist（`/tf/playlist.m3u8?…`）：带 `X-Radiko-AuthToken` + `X-Radiko-AreaId`。
    ///   2. chunklist：**裸请求，不带任何头**。
    ///   3. `.aac` 分片：**裸请求**（rajiko 用 `credentials: "omit"`）。
    /// 按 +300s 递增 `seek` 逐窗抓取，直到覆盖整段。
    static func download(stationID: String, areaID: String,
                         start: Date, end: Date, into directory: URL) async throws -> URL {
        let base = try await RadikoStream.fetchTimefreeBase(stationID: stationID)
        let session = HLSRecorderKit.makeSession(timeout: 30)

        let startStamp = HLSRecorderKit.stamp.string(from: start)
        let endStamp = HLSRecorderKit.stamp.string(from: end)

        let writer = SegmentWriter(directory: directory, baseName: UUID().uuidString)
        var seen = Set<String>()
        var windows = 0
        var segmentsTried = 0
        var lastError: Error?

        var seek = start
        let step = TimeInterval(RadikoStream.timefreeSeekStep)

        while seek < end {
            if Task.isCancelled { break }
            windows += 1
            // 每窗都取一次 token：缓存过期会自动重新鉴权（长节目抓到一半 token 失效是常态），
            // lsid 也跟着 token 走，保证与鉴权时的 X-Radiko-User 一致。
            let token = try await RadikoAuthenticator.shared.token(preferredArea: areaID)
            let plURL = RadikoStream.timefreePlaylistURL(
                base: base, stationID: stationID, lsid: token.userID,
                startAt: startStamp, endAt: endStamp,
                seek: HLSRecorderKit.stamp.string(from: seek))
            let plHeaders = ["X-Radiko-AuthToken": token.value, "X-Radiko-AreaId": token.area]

            var text: String
            do {
                text = try await HLSRecorderKit.getText(plURL, headers: plHeaders,
                                                       session: session, stage: "playlist")
            } catch {
                lastError = error
                // 401/403/expired：换一个 token 立刻重试这一窗，不整段放弃。
                guard Self.isAuthFailure(error),
                      let fresh = try? await RadikoAuthenticator.shared.refresh(area: areaID) else {
                    seek = seek.addingTimeInterval(step)
                    continue
                }
                let retryURL = RadikoStream.timefreePlaylistURL(
                    base: base, stationID: stationID, lsid: fresh.userID,
                    startAt: startStamp, endAt: endStamp,
                    seek: HLSRecorderKit.stamp.string(from: seek))
                do {
                    text = try await HLSRecorderKit.getText(
                        retryURL,
                        headers: ["X-Radiko-AuthToken": fresh.value, "X-Radiko-AreaId": fresh.area],
                        session: session, stage: "playlist(retry)")
                } catch {
                    lastError = error
                    seek = seek.addingTimeInterval(step)
                    continue
                }
            }

            var pl = HLSRecorderKit.parse(text, base: plURL)
            // master → chunklist：裸请求（带 radiko 头会被 CDN 拒）。最多展开三层。
            var depth = 0
            while pl.segments.isEmpty, let sub = pl.subPlaylists.first, depth < 3 {
                depth += 1
                do {
                    let chunkText = try await HLSRecorderKit.getText(sub, session: session, stage: "chunklist")
                    pl = HLSRecorderKit.parse(chunkText, base: sub)
                } catch {
                    lastError = error
                    break
                }
            }

            if let initSeg = pl.initSegment, !seen.contains(initSeg.absoluteString) {
                segmentsTried += 1
                if let d = await HLSRecorderKit.fetchSegment(initSeg, headers: [:], session: session) {
                    seen.insert(initSeg.absoluteString)
                    writer.append(d)
                }
            }
            for seg in pl.segments where !seen.contains(seg.absoluteString) {
                if Task.isCancelled { break }
                segmentsTried += 1
                // 只有真的下到数据才记为已抓——否则失败的分片会被误判成「抓过了」，
                // 最后留下一个 0 字节的文件被当成录音入库。
                switch await HLSRecorderKit.fetchNode(seg, headers: [:], session: session) {
                case .media(let d):
                    seen.insert(seg.absoluteString)
                    writer.append(d)
                case .playlist(let nested):
                    // 这一层其实又是播放列表（地址不带 .m3u8 后缀时会走到这儿）：再展开一层。
                    seen.insert(seg.absoluteString)
                    let inner = HLSRecorderKit.parse(nested, base: seg)
                    for s2 in inner.segments where !seen.contains(s2.absoluteString) {
                        if Task.isCancelled { break }
                        segmentsTried += 1
                        if let d = await HLSRecorderKit.fetchSegment(s2, headers: [:], session: session) {
                            seen.insert(s2.absoluteString)
                            writer.append(d)
                        }
                    }
                case nil:
                    break
                }
            }
            seek = seek.addingTimeInterval(step)
        }

        // 部分成功也算成功，宁可短不可无。重封装成 m4a 才有时长、才能拖进度条。
        if let url = writer.finish() { return await AudioRemuxer.toM4A(url) }
        // 走到这里说明一个字节都没写下：把最能说明问题的那个原因抛出去。
        if let lastError { throw lastError }
        if segmentsTried == 0 { throw RecordingError.noSegments(windows: windows) }
        if seen.isEmpty { throw RecordingError.allSegmentsFailed(tried: segmentsTried) }
        throw RecordingError.emptyOutput
    }

    private static func isAuthFailure(_ error: Error) -> Bool {
        switch error {
        case RecordingError.tokenExpired: return true
        case RecordingError.http(_, let status): return status == 401 || status == 403
        default: return false
        }
    }
}

// MARK: - 实时录制（手动录制 / App 活跃时的尽力预约）

enum LiveRecorder {
    /// 持续抓直播流写入 `directory/<filename>.<ext>`，直到所在 Task 被取消。
    /// 返回写入的文件（无数据则返回 nil 并清理）。仅在 App 存活时持续（iOS 限制）。
    static func capture(station: Station, into directory: URL, filename: String) async -> URL? {
        let session = HLSRecorderKit.makeSession(timeout: 20)
        guard var resolved = try? await resolveChunklist(station: station, session: session) else {
            return nil
        }

        let writer = SegmentWriter(directory: directory, baseName: filename)
        var lastSeq = -1
        var seenURLs = Set<String>()
        var wroteInit = false
        var failures = 0

        while !Task.isCancelled {
            if let text = try? await HLSRecorderKit.getText(resolved.0, headers: resolved.1,
                                                           session: session, stage: "live chunklist") {
                failures = 0
                let pl = HLSRecorderKit.parse(text, base: resolved.0)

                if !wroteInit, let initSeg = pl.initSegment,
                   let d = await HLSRecorderKit.fetchSegment(initSeg, headers: resolved.1, session: session) {
                    writer.append(d)
                    wroteInit = true
                }
                for (i, seg) in pl.segments.enumerated() {
                    if Task.isCancelled { break }
                    let seq = pl.mediaSequence + i
                    // 双重去重：媒体序号（正常情形）+ URL（服务端序号回绕/重置时兜底）。
                    if seq <= lastSeq || seenURLs.contains(seg.absoluteString) { continue }
                    if let d = await HLSRecorderKit.fetchSegment(seg, headers: resolved.1, session: session) {
                        writer.append(d)
                        lastSeq = seq
                        seenURLs.insert(seg.absoluteString)
                    }
                }
                if pl.isEndlist { break }
            } else {
                failures += 1
                // chunklist 的会话参数可能过期 —— 重新解析一次再放弃。
                if failures == 3, let again = try? await resolveChunklist(station: station, session: session) {
                    resolved = again
                } else if failures >= 6 {
                    break
                }
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
        }

        guard let url = writer.finish() else { return nil }
        return await AudioRemuxer.toM4A(url)
    }

    /// 抓「最近 `seconds` 秒」的直播音频，供**内源识曲**用（不经麦克风）。
    ///
    /// 直播 chunklist 里通常已经缓存了十几到几十秒，所以**从末尾往回数**取够时长就行：
    /// 一次请求即可拿到刚播出的那几秒。从头开始取会拿到半分钟前的内容，
    /// 识别出来的常常是上一首歌。
    ///
    /// 返回可被 `AVAsset` 解码的文件（拼出来的裸 ADTS 会先重封成 m4a）。调用方负责删除。
    static func snippet(station: Station, seconds: Double, into directory: URL) async -> URL? {
        let session = HLSRecorderKit.makeSession(timeout: 15)
        guard let resolved = try? await resolveChunklist(station: station, session: session) else {
            return nil
        }
        let (chunklist, headers) = resolved
        guard let text = try? await HLSRecorderKit.getText(chunklist, headers: headers,
                                                          session: session, stage: "snippet chunklist")
        else { return nil }

        let pl = HLSRecorderKit.parse(text, base: chunklist)
        guard !pl.segments.isEmpty else { return nil }

        // 从末尾往回累计 EXTINF 时长（没有该标签时按 5 秒一片估）。
        let take = HLSRecorderKit.tailCount(durations: pl.durations, seconds: seconds)

        let writer = SegmentWriter(directory: directory, baseName: "snippet-\(UUID().uuidString)")
        // fMP4 必须先写 init 段，否则拿到的只是一段无法解码的裸 moof。
        if let initSeg = pl.initSegment,
           let d = await HLSRecorderKit.fetchSegment(initSeg, headers: headers, session: session) {
            writer.append(d)
        }
        for seg in pl.segments.suffix(take) {
            if Task.isCancelled { break }
            if let d = await HLSRecorderKit.fetchSegment(seg, headers: headers, session: session) {
                writer.append(d)
            }
        }
        guard let url = writer.finish() else { return nil }
        return await AudioRemuxer.toM4A(url)
    }

    /// 解析出可轮询的 chunklist URL 与所需请求头（直连台带浏览器头，radiko 带 token）。
    private static func resolveChunklist
(station: Station, session: URLSession) async throws -> (URL, [String: String]) {
        let headers: [String: String]
        let master: URL

        if let direct = station.directStreamURL, let url = URL(string: direct) {
            headers = [
                "User-Agent": RadioPlayer.browserUserAgent,
                "Referer": "https://listenradio.jp/",
                "Origin": "https://listenradio.jp",
            ]
            master = url
        } else {
            let token = try await RadikoAuthenticator.shared.token(preferredArea: station.areaID)
            headers = ["X-Radiko-AuthToken": token.value]
            master = try await RadikoStream.playlistURL(for: station, token: token)
        }

        let text = try await HLSRecorderKit.getText(master, headers: headers,
                                                   session: session, stage: "live master")
        let pl = HLSRecorderKit.parse(text, base: master)
        if pl.segments.isEmpty, let sub = pl.subPlaylists.first {
            // master → chunklist 可能有两层，再展开一次。
            if let subText = try? await HLSRecorderKit.getText(sub, headers: headers,
                                                              session: session, stage: "live sub") {
                let inner = HLSRecorderKit.parse(subText, base: sub)
                if inner.segments.isEmpty, let deeper = inner.subPlaylists.first {
                    return (deeper, headers)
                }
            }
            return (sub, headers)
        }
        return (master, headers)
    }
}

// MARK: - 重封装（拼出来的裸 AAC → m4a）

/// 把分片拼接出来的音频重新封成 m4a。
///
/// HLS 分片直接首尾相接得到的是**裸 ADTS**：没有容器、没有时长、没有采样索引。
/// AVPlayer 对这种文件的 `duration` 会给 `indefinite` —— 进度条不知道总长，
/// 拖动也无处可定位。过一遍 passthrough 导出（只换壳、不重编码、不掉音质）
/// 就有了正常时长与索引，拖动才准；顺带导出的文件在别的播放器里也更规矩。
///
/// 任何一步不顺就原样返回：宁可留一个只能顺序播的录音，也绝不把录到的东西弄丢。
enum AudioRemuxer {

    /// 用 detached 任务跑：手动停止录制时外层 Task 已被取消，
    /// 若继承取消状态，导出会在开头就被掐掉，录到的东西就白拖不了进度条。
    static func toM4A(_ url: URL) async -> URL {
        await Task.detached(priority: .utility) { await remux(url) }.value
    }

    private static func remux(_ url: URL) async -> URL {
        let ext = url.pathExtension.lowercased()
        guard ext != "m4a", ext != "mp3" else { return url }

        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset,
                                                presetName: AVAssetExportPresetPassthrough) else { return url }
        let output = url.deletingPathExtension().appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: output)

        if #available(iOS 18.0, *) {
            do { try await session.export(to: output, as: .m4a) }
            catch { try? FileManager.default.removeItem(at: output); return url }
        } else {
            session.outputURL = output
            session.outputFileType = .m4a
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { continuation.resume() }
            }
            guard session.status == .completed else {
                try? FileManager.default.removeItem(at: output)
                return url
            }
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: output.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            try? FileManager.default.removeItem(at: output)
            return url
        }
        try? FileManager.default.removeItem(at: url)
        return output
    }
}

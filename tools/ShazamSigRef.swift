// ShazamKit 参考指纹生成器 —— web 版识曲的**对照标尺**，不参与 app 构建。
//
//   SDK=/Applications/xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
//   swiftc -sdk "$SDK" -module-cache-path "$TMPDIR/mcache" -disable-sandbox \
//          -O -parse-as-library -o "$TMPDIR/shazamsig" tools/ShazamSigRef.swift
//   "$TMPDIR/shazamsig" 输入.wav 输出.sig
//
// （`-module-cache-path` 与 `-disable-sandbox` 不是可选的：默认的 module cache 在
//   DARWIN_USER_TEMP_DIR 下，这台机器上不可写，缺了会报「unable to load standard library」。
//   `-parse-as-library` 是因为入口是 `@main` 而不是 main.swift 的顶层代码。
//   编译时刷出来的 `couldn't create cache file '…/xcrun_db-…'` 是同一个原因，无害。）
//
// 为什么需要它：web 版没有 ShazamKit，指纹必须用 JS 自己算（见 web/lib/shazam.mjs）。
// 而那个算法一旦有偏差，`amp.shazam.com` 只会回一句 `200 no match` —— 从响应里
// 完全看不出错在哪一步。所以这里让 ShazamKit 对同一段音频算一份，
// 拿来跟 JS 的输出做对照（`node web/test/sigdiff.mjs diff`）。
//
// 输出的是**剥壳后**的 Shazam 原生签名（`0xcafe2580` 开头），
// 也就是 ShazamWebMatcher.unwrap 送出去的那份。
import AVFoundation
import Foundation
import ShazamKit

@main
struct ShazamSigRef {

    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            FileHandle.standardError.write(Data("用法：shazamsig <输入音频> <输出.sig>\n".utf8))
            exit(2)
        }
        let input = URL(fileURLWithPath: args[1])
        let output = URL(fileURLWithPath: args[2])
        do {
            let signature = try generate(from: input)
            let raw = signature.dataRepresentation
            let bare = unwrap(raw)
            try bare.write(to: output)
            // 印出来的这几项就是对照时最先看的：壳的偏移、剥出来的魔数、字节数、时长。
            print("wrapped \(raw.count)B  magic \(hex(raw.prefix(4)))")
            print("bare    \(bare.count)B  magic \(hex(bare.prefix(4)))  dur \(signature.duration)s")
        } catch {
            FileHandle.standardError.write(Data("失败：\(error)\n".utf8))
            exit(1)
        }
    }

    /// 走 `AVAudioFile` + `SHSignatureGenerator.append`，**不**走
    /// `SHSignatureGenerator.signature(from: AVURLAsset)`。
    ///
    /// 后者在这台机器的沙箱里必然失败（`ShazamKit Code=500` 套着
    /// `AVFoundationErrorDomain Code=-11800 / OSStatus -1`）—— AVAssetReader 那条路
    /// 要用到取不到的媒体服务。`AVAudioFile` 直接读文件，不依赖任何守护进程。
    ///
    /// 顺便还更可控：这里显式转成 **16 kHz 单声道 float32** 再喂进去，
    /// 与 JS 侧的输入完全同一份采样，省掉「重采样差异」这个变量。
    static func generate(from url: URL) throws -> SHSignature {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard let frames = AVAudioFrameCount(exactly: file.length), frames > 0 else {
            throw Failure("音频长度为 0")
        }
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames) else {
            throw Failure("分配输入缓冲失败")
        }
        try file.read(into: input)

        let generator = SHSignatureGenerator()
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16000, channels: 1, interleaved: false) else {
            throw Failure("构造目标格式失败")
        }
        if source.sampleRate == target.sampleRate, source.channelCount == target.channelCount,
           source.commonFormat == target.commonFormat {
            try generator.append(input, at: nil)      // 已经是 16 kHz 单声道，直接喂
        } else {
            try generator.append(convert(input, to: target), at: nil)
        }
        return generator.signature()
    }

    /// 一次性重采样（输入整段都在内存里，不需要流式喂）。
    static func convert(_ input: AVAudioPCMBuffer, to target: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: input.format, to: target) else {
            throw Failure("构造 AVAudioConverter 失败")
        }
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw Failure("分配输出缓冲失败")
        }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error { throw error ?? Failure("重采样失败") }
        return output
    }

    /// 与 ShazamWebMatcher.unwrap 同一份逻辑（偏移从第 8 字节读，不写死 12）。
    static func unwrap(_ data: Data) -> Data {
        guard data.count > 16 else { return data }
        let base = data.startIndex
        let offset = data[(base + 8) ..< (base + 12)].enumerated()
            .reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        guard offset >= 12, offset + 4 <= data.count,
              Array(data[(base + offset) ..< (base + offset + 4)]) == [0x80, 0x25, 0xfe, 0xca]
        else { return data }
        return Data(data.dropFirst(offset))
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

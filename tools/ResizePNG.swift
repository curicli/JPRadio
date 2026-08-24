// PNG 缩放小工具（在 Mac 上跑；放在 JPRadio/ 之外，不会被编译进 iOS target）。
//
//   SDK=/Applications/xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
//   swiftc -sdk "$SDK" -O -o /tmp/resizepng tools/ResizePNG.swift
//   /tmp/resizepng in.png out.png 120
//
// 存在的理由：打未签名 ipa 时要从 1024 母图切出旧式 app 图标，而 `sips` 在本机这套
// 沙箱里跑不了（它往 DARWIN_USER_TEMP_DIR 写中间文件，那个目录不可写，且不认 TMPDIR）。
// 这里直接 CoreGraphics 重绘一张，不落中间文件。
import AppKit

let args = CommandLine.arguments
guard args.count == 4, let side = Int(args[3]), side > 0 else {
    FileHandle.standardError.write(Data("usage: resizepng <in.png> <out.png> <side>\n".utf8))
    exit(2)
}

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write(Data("cannot read \(args[1])\n".utf8))
    exit(1)
}

// 不透明上下文（noneSkipLast）：app 图标不该带 alpha 通道。
guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    exit(1)
}
ctx.interpolationQuality = .high
ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

guard let out = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL,
                                                 "public.png" as CFString, 1, nil) else {
    exit(1)
}
CGImageDestinationAddImage(dest, out, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }

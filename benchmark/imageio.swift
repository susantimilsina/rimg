// Apple ImageIO baseline (what flutter_image_compress uses on iOS/macOS, best case).
// swiftc -O imageio.swift -o imageio && ./imageio in.jpg maxSide quality out.jpg
import Foundation
import ImageIO
import UniformTypeIdentifiers
let a = CommandLine.arguments
let data = try! Data(contentsOf: URL(fileURLWithPath: a[1])) as CFData
let maxSide = Int(a[2])!, q = Double(a[3])! / 100
func run() -> Data {
    let src = CGImageSourceCreateWithData(data, nil)!
    let img: CGImage
    if maxSide > 0 {
        img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true] as CFDictionary)!
    } else {
        img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)!
    }
    let out = NSMutableData()
    let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
    CGImageDestinationFinalize(dst)
    return out as Data
}
_ = run()
var times: [Double] = []; var result = Data()
for _ in 0..<5 { let t = Date(); result = run(); times.append(Date().timeIntervalSince(t) * 1000) }
times.sort()
try! result.write(to: URL(fileURLWithPath: a[4]))
print(String(format: "imageio %6.0f ms %6.0f KB", times[2], Double(result.count) / 1024))

// Writes a small HEIC tagged with EXIF orientation 6 (rotate 90° CW), for tests.
// swiftc make_heic.swift -o make_heic && ./make_heic in.jpg out.heic
import Foundation
import ImageIO
import UniformTypeIdentifiers
let a = CommandLine.arguments
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil)!
let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary)!  // 400x300 landscape
let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[2]) as CFURL, UTType.heic.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dst, img, [kCGImagePropertyOrientation: 6, kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
precondition(CGImageDestinationFinalize(dst))

#!/usr/bin/env swift
//
// gifify.swift — assemble an ordered set of PNG frames into an animated GIF using macOS ImageIO.
//
// The repo's core/daemon/CLI are dependency-free by design, and the doc images shouldn't be the
// thing that forces ffmpeg/ImageMagick/gifski onto a contributor's box. ImageIO ships with macOS
// and writes animated GIFs natively (CGImageDestination + kUTTypeGIF), so the whole encoder is
// this file.
//
// Frames are downscaled to a target width (README GIFs render ~900pt wide; a Retina window capture
// is 2-3x that, and an un-downscaled GIF is enormous for no visible gain).
//
// Usage: swift scripts/gifify.swift <out.gif> <delay-seconds> <max-width-px> <frame.png>...
//   e.g. swift scripts/gifify.swift docs/images/keyboard.gif 0.5 1200 .scratch/frames/*.png

import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 4 else {
    FileHandle.standardError.write(Data("usage: gifify.swift <out.gif> <delay-s> <max-width-px> <frame.png>...\n".utf8))
    exit(2)
}
let outPath = args[0]
let delay = Double(args[1]) ?? 0.5
let maxWidth = Double(args[2]) ?? 1200
let frames = Array(args.dropFirst(3))

// Downscale a frame to maxWidth, preserving aspect. ImageIO's thumbnail path does this in one shot
// and never upscales below the source (kCGImageSourceCreateThumbnailFromImageAlways is bounded by
// the max-pixel-size hint).
func loadFrame(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    guard let full = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = Double(full.width)
    guard w > maxWidth else { return full }
    let scale = maxWidth / w
    let maxPixel = max(Double(full.width), Double(full.height)) * scale
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel.rounded()),
        kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) ?? full
}

guard let dest = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: outPath) as CFURL, UTType.gif.identifier as CFString, frames.count, nil
) else {
    FileHandle.standardError.write(Data("gifify: cannot create \(outPath)\n".utf8))
    exit(1)
}

// loopCount 0 == loop forever.
CGImageDestinationSetProperties(dest, [
    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
] as CFDictionary)

let frameProps = [
    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: delay,
                                    kCGImagePropertyGIFDelayTime: delay]
] as CFDictionary

var added = 0
for f in frames {
    guard let img = loadFrame(f) else {
        FileHandle.standardError.write(Data("gifify: skipping unreadable frame \(f)\n".utf8))
        continue
    }
    CGImageDestinationAddImage(dest, img, frameProps)
    added += 1
}

guard added > 0, CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write(Data("gifify: failed to write \(outPath) (\(added) frames)\n".utf8))
    exit(1)
}

let bytes = ((try? FileManager.default.attributesOfItem(atPath: outPath))?[.size] as? Int) ?? 0
print("gifify: wrote \(outPath) — \(added) frames, \(String(format: "%.1f", Double(bytes) / 1_048_576))MB")

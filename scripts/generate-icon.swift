#!/usr/bin/env swift

import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fputs("用法：generate-icon.swift <源PNG> <输出.iconset目录>\n", stderr)
    exit(1)
}

let sourceURL = URL(fileURLWithPath: arguments[1])
let outputDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
let fileManager = FileManager.default

guard let sourceImage = NSImage(contentsOf: sourceURL),
      let sourceCGImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("无法读取图标母图：\(sourceURL.path)\n", stderr)
    exit(1)
}

do {
    if fileManager.fileExists(atPath: outputDirectory.path) {
        try fileManager.removeItem(at: outputDirectory)
    }
    try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
} catch {
    fputs("无法准备图标目录：\(error.localizedDescription)\n", stderr)
    exit(1)
}

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func resizedPNG(pixels: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        return nil
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    context.cgContext.interpolationQuality = .high
    context.cgContext.draw(
        sourceCGImage,
        in: CGRect(x: 0, y: 0, width: pixels, height: pixels)
    )
    NSGraphicsContext.restoreGraphicsState()

    return bitmap.representation(using: .png, properties: [:])
}

for variant in variants {
    guard let data = resizedPNG(pixels: variant.pixels) else {
        fputs("无法缩放图标：\(variant.name)\n", stderr)
        exit(1)
    }

    do {
        try data.write(to: outputDirectory.appendingPathComponent(variant.name))
    } catch {
        fputs("无法写入图标 \(variant.name)：\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

print("图标素材生成完成：\(outputDirectory.path)")

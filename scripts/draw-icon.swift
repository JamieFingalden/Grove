#!/usr/bin/env swift

import AppKit
import Foundation

// 生成 Grove 的图标母图（1024×1024 PNG）。
//
// 图形是一张 git 提交图：一条主干加两条分叉，每条末端一个节点 ——
// 既是「分支」也是「一片树林」，正好是这个工具在做的事。
// 用代码画而不是放一张设计稿，是为了让图标跟着仓库走，不依赖外部资源。

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fputs("用法：draw-icon.swift <输出.png>\n", stderr)
    exit(1)
}
let outputURL = URL(fileURLWithPath: arguments[1])

let canvas: CGFloat = 1024
// macOS 图标的实际图形区域比画布小一圈，系统会在四周留出投影空间。
let inset: CGFloat = 100
let plate = CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
let cornerRadius = plate.width * 0.2237   // Apple 的连续圆角比例

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else {
    fputs("无法创建位图\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
guard let context = NSGraphicsContext.current?.cgContext else { exit(1) }
context.setShouldAntialias(true)
context.interpolationQuality = .high

// MARK: - 底板

let plateShape = NSBezierPath(roundedRect: plate, xRadius: cornerRadius, yRadius: cornerRadius)

context.saveGState()
plateShape.addClip()
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.055, green: 0.310, blue: 0.247, alpha: 1),   // 深墨绿
    NSColor(srgbRed: 0.086, green: 0.522, blue: 0.373, alpha: 1),   // 中绿
    NSColor(srgbRed: 0.180, green: 0.706, blue: 0.518, alpha: 1)    // 亮绿
])
gradient?.draw(in: plate, angle: 62)

// 左上角一层柔和高光，让底板不至于是一块死板的渐变。
let highlight = NSGradient(colors: [
    NSColor(white: 1, alpha: 0.20),
    NSColor(white: 1, alpha: 0.0)
])
highlight?.draw(
    fromCenter: CGPoint(x: plate.minX + plate.width * 0.22, y: plate.maxY - plate.height * 0.14),
    radius: 0,
    toCenter: CGPoint(x: plate.minX + plate.width * 0.25, y: plate.maxY - plate.height * 0.18),
    radius: plate.width * 0.72,
    options: []
)
context.restoreGState()

// MARK: - 分支图

let stroke = plate.width * 0.068
let nodeRadius = stroke * 1.18
let ink = NSColor(white: 1, alpha: 0.97)

let centerX = plate.midX
let bottomY = plate.minY + plate.height * 0.17
let topY = plate.maxY - plate.height * 0.17
let span = topY - bottomY
let spread = plate.width * 0.225

/// 从主干上某个高度分叉出去，再竖直向上到末端。
/// 用三次贝塞尔画出的圆角拐弯，比直角折线更像 GitHub 上的提交图。
func branch(toX targetX: CGFloat, forkAt forkFraction: CGFloat, endAt endFraction: CGFloat) -> NSBezierPath {
    let forkY = bottomY + span * forkFraction
    let endY = bottomY + span * endFraction
    // 拐弯要占掉一段垂直距离。不夹住的话拐点会冲到终点上方，
    // 于是线条越过节点继续往上，看起来像画错了 —— 第一版就是这么翻车的。
    let turnY = min(forkY + abs(targetX - centerX) * 0.62, endY)

    let path = NSBezierPath()
    path.move(to: CGPoint(x: centerX, y: forkY))
    path.curve(
        to: CGPoint(x: targetX, y: turnY),
        controlPoint1: CGPoint(x: centerX, y: forkY + (turnY - forkY) * 0.62),
        controlPoint2: CGPoint(x: targetX, y: forkY + (turnY - forkY) * 0.38)
    )
    path.line(to: CGPoint(x: targetX, y: endY))
    path.lineWidth = stroke
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    return path
}

ink.setStroke()
ink.setFill()

// 主干
let trunk = NSBezierPath()
trunk.move(to: CGPoint(x: centerX, y: bottomY))
trunk.line(to: CGPoint(x: centerX, y: topY))
trunk.lineWidth = stroke
trunk.lineCapStyle = .round
trunk.stroke()

// 两条分叉高度错开：完全对称会像个几何符号，错开才有「生长」的感觉。
let rightEnd: CGFloat = 0.80
let leftEnd: CGFloat = 0.58
branch(toX: centerX + spread, forkAt: 0.16, endAt: rightEnd).stroke()
branch(toX: centerX - spread, forkAt: 0.36, endAt: leftEnd).stroke()

func node(_ point: CGPoint) {
    NSBezierPath(ovalIn: CGRect(
        x: point.x - nodeRadius, y: point.y - nodeRadius,
        width: nodeRadius * 2, height: nodeRadius * 2
    )).fill()
}

// 实心圆点，不挖洞：16×16 的菜单栏尺寸下任何内部细节都会糊成一团，
// 挖了洞反而让节点看起来脏。
node(CGPoint(x: centerX, y: bottomY))
node(CGPoint(x: centerX, y: topY))
node(CGPoint(x: centerX + spread, y: bottomY + span * rightEnd))
node(CGPoint(x: centerX - spread, y: bottomY + span * leftEnd))

NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fputs("无法编码 PNG\n", stderr)
    exit(1)
}

do {
    try data.write(to: outputURL)
    print("图标已生成：\(outputURL.path)")
} catch {
    fputs("写入失败：\(error.localizedDescription)\n", stderr)
    exit(1)
}

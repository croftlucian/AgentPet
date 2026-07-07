import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let skinURL = root.appendingPathComponent("Resources/agent-pet-skin.png")
let outDir = root.appendingPathComponent("design-previews/task-complete-leg-bend-sequence", isDirectory: true)
let sheetURL = root.appendingPathComponent("design-previews/task-complete-leg-bend-sequence-sheet.png")
let gifURL = root.appendingPathComponent("design-previews/task-complete-leg-bend-sequence.gif")

guard let skin = NSImage(contentsOf: skinURL) else {
    fatalError("无法读取皮肤资源：\(skinURL.path)")
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let frameSize = CGSize(width: 512, height: 512)
let orange = NSColor(srgbRed: 0xF0 / 255.0, green: 0x52 / 255.0, blue: 0x22 / 255.0, alpha: 1.0)
let orangeDark = NSColor(srgbRed: 0x96 / 255.0, green: 0x2F / 255.0, blue: 0x15 / 255.0, alpha: 1.0)
let face = NSColor(srgbRed: 0.36, green: 0.10, blue: 0.05, alpha: 1)

struct Pose {
    let name: String
    let bodyYOffset: CGFloat
    let scaleX: CGFloat
    let scaleY: CGFloat
    let legAlpha: CGFloat
    let leftLeg: [CGPoint]
    let rightLeg: [CGPoint]
}

func savePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("PNG 编码失败：\(url.path)")
    }
    try png.write(to: url, options: .atomic)
}

func saveGIF(_ frames: [NSImage], to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
        fatalError("GIF 创建失败：\(url.path)")
    }
    let gifProperties: [CFString: Any] = [
        kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFLoopCount: 0
        ]
    ]
    let delays: [Double] = [0.12, 0.10, 0.12, 0.14, 0.11, 0.18]
    for (index, image) in frames.enumerated() {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { continue }
        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delays[min(index, delays.count - 1)]
            ]
        ]
        CGImageDestinationAddImage(destination, cgImage, frameProperties as CFDictionary)
    }
    CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("GIF 写入失败：\(url.path)")
    }
}

func drawPixelRect(_ rect: CGRect, color: NSColor) {
    color.setFill()
    rect.integral.fill()
}

func drawSegment(_ points: [CGPoint], color: NSColor, width: CGFloat) {
    guard points.count >= 2, let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.setShouldAntialias(false)
    ctx.setLineCap(.butt)
    ctx.setLineJoin(.miter)
    ctx.setStrokeColor(color.cgColor)
    ctx.setLineWidth(width)
    ctx.beginPath()
    ctx.move(to: points[0])
    for point in points.dropFirst() {
        ctx.addLine(to: point)
    }
    ctx.strokePath()
}

func drawLeg(_ points: [CGPoint], alpha: CGFloat) {
    let dark = orangeDark.withAlphaComponent(alpha)
    let main = orange.withAlphaComponent(alpha)
    let shadowOffset = CGSize(width: 4, height: -5)
    let shadowPoints = points.map { CGPoint(x: $0.x + shadowOffset.width, y: $0.y + shadowOffset.height) }
    drawSegment(shadowPoints, color: dark, width: 19)
    drawSegment(points, color: main, width: 15)

    guard points.count >= 2, let foot = points.last else { return }
    let prev = points[points.count - 2]
    let footWidth: CGFloat = 36
    let footHeight: CGFloat = 17
    let leansRight = foot.x >= prev.x
    let footRect = CGRect(x: foot.x - (leansRight ? 12 : footWidth - 12),
                          y: foot.y - 9,
                          width: footWidth,
                          height: footHeight)
    drawPixelRect(footRect.offsetBy(dx: shadowOffset.width, dy: shadowOffset.height), color: dark)
    drawPixelRect(footRect, color: main)
}

func drawHappyFace(in bodyRect: CGRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.setShouldAntialias(false)
    ctx.setStrokeColor(face.cgColor)
    ctx.setFillColor(face.cgColor)
    ctx.setLineCap(.round)
    ctx.setLineWidth(min(bodyRect.width, bodyRect.height) * 0.014)

    let unit = min(bodyRect.width, bodyRect.height)
    let eyeSize = CGSize(width: unit * 0.028, height: unit * 0.067)
    let radius = eyeSize.width * 1.1
    let centers = [
        CGPoint(x: bodyRect.minX + bodyRect.width * 0.405, y: bodyRect.minY + bodyRect.height * 0.523),
        CGPoint(x: bodyRect.minX + bodyRect.width * 0.595, y: bodyRect.minY + bodyRect.height * 0.523),
    ]
    for center in centers {
        ctx.beginPath()
        ctx.addArc(center: CGPoint(x: center.x, y: center.y - radius * 0.35),
                   radius: radius,
                   startAngle: .pi * 0.18,
                   endAngle: .pi * 0.82,
                   clockwise: false)
        ctx.strokePath()
    }

    let mouthCenter = CGPoint(x: bodyRect.midX, y: bodyRect.minY + bodyRect.height * 0.418)
    let mouth = CGRect(x: mouthCenter.x - unit * 0.058,
                       y: mouthCenter.y - unit * 0.034 * 0.75,
                       width: unit * 0.116,
                       height: unit * 0.068 * 0.75)
    ctx.fillEllipse(in: mouth)
}

func drawBody(pose: Pose) -> CGRect {
    let base = frameSize.width * 0.90
    let bodySize = CGSize(width: base * pose.scaleX, height: base * pose.scaleY)
    let bodyRect = CGRect(x: (frameSize.width - bodySize.width) / 2,
                          y: (frameSize.height - bodySize.height) / 2 + pose.bodyYOffset,
                          width: bodySize.width,
                          height: bodySize.height)
    NSGraphicsContext.current?.imageInterpolation = .none
    skin.draw(in: bodyRect, from: .zero, operation: .sourceOver, fraction: 1)
    return bodyRect
}

func clearOriginalLegs(in bodyRect: CGRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.saveGState()
    ctx.setBlendMode(.clear)
    // 只擦原腿下半段和脚掌。腿根留给新腿覆盖,避免把身体底部挖出透明洞造成变形。
    let regions = [
        CGRect(x: 0.410, y: 0.070, width: 0.065, height: 0.150),
        CGRect(x: 0.525, y: 0.070, width: 0.065, height: 0.150),
        CGRect(x: 0.375, y: 0.055, width: 0.130, height: 0.055),
        CGRect(x: 0.495, y: 0.055, width: 0.130, height: 0.055),
    ]
    for region in regions {
        let rect = CGRect(x: bodyRect.minX + bodyRect.width * region.minX,
                          y: bodyRect.minY + bodyRect.height * region.minY,
                          width: bodyRect.width * region.width,
                          height: bodyRect.height * region.height)
        ctx.fill(rect)
    }
    ctx.restoreGState()
}

func point(_ bodyRect: CGRect, _ normalized: CGPoint) -> CGPoint {
    CGPoint(x: bodyRect.minX + bodyRect.width * normalized.x,
            y: bodyRect.minY + bodyRect.height * normalized.y)
}

func renderFrame(pose: Pose) -> NSImage {
    let image = NSImage(size: frameSize)
    image.lockFocus()
    NSColor.clear.setFill()
    CGRect(origin: .zero, size: frameSize).fill()
    let bodyRect = drawBody(pose: pose)
    clearOriginalLegs(in: bodyRect)
    drawLeg(pose.leftLeg.map { point(bodyRect, $0) }, alpha: pose.legAlpha)
    drawLeg(pose.rightLeg.map { point(bodyRect, $0) }, alpha: pose.legAlpha)
    drawHappyFace(in: bodyRect)
    image.unlockFocus()
    return image
}

func drawChecker(in rect: CGRect, cell: CGFloat = 16) {
    let a = NSColor(srgbRed: 0.18, green: 0.19, blue: 0.22, alpha: 1)
    let b = NSColor(srgbRed: 0.25, green: 0.26, blue: 0.30, alpha: 1)
    var y = rect.minY
    var row = 0
    while y < rect.maxY {
        var x = rect.minX
        var col = 0
        while x < rect.maxX {
            ((row + col).isMultiple(of: 2) ? a : b).setFill()
            CGRect(x: x, y: y, width: cell, height: cell).fill()
            x += cell
            col += 1
        }
        y += cell
        row += 1
    }
}

let poses: [Pose] = [
    Pose(name: "stand", bodyYOffset: 0, scaleX: 1.0, scaleY: 1.0, legAlpha: 1.0,
         leftLeg: [CGPoint(x: 0.445, y: 0.310), CGPoint(x: 0.445, y: 0.195), CGPoint(x: 0.425, y: 0.095)],
         rightLeg: [CGPoint(x: 0.555, y: 0.310), CGPoint(x: 0.555, y: 0.195), CGPoint(x: 0.575, y: 0.095)]),
    Pose(name: "crouch", bodyYOffset: -18, scaleX: 1.08, scaleY: 0.88, legAlpha: 1.0,
         leftLeg: [CGPoint(x: 0.445, y: 0.292), CGPoint(x: 0.405, y: 0.235), CGPoint(x: 0.435, y: 0.165)],
         rightLeg: [CGPoint(x: 0.555, y: 0.292), CGPoint(x: 0.595, y: 0.235), CGPoint(x: 0.565, y: 0.165)]),
    Pose(name: "launch", bodyYOffset: 52, scaleX: 0.97, scaleY: 1.05, legAlpha: 1.0,
         leftLeg: [CGPoint(x: 0.445, y: 0.292), CGPoint(x: 0.430, y: 0.220), CGPoint(x: 0.410, y: 0.145)],
         rightLeg: [CGPoint(x: 0.555, y: 0.292), CGPoint(x: 0.570, y: 0.220), CGPoint(x: 0.590, y: 0.145)]),
    Pose(name: "air", bodyYOffset: 104, scaleX: 0.98, scaleY: 1.02, legAlpha: 1.0,
         leftLeg: [CGPoint(x: 0.445, y: 0.292), CGPoint(x: 0.412, y: 0.238), CGPoint(x: 0.370, y: 0.165)],
         rightLeg: [CGPoint(x: 0.555, y: 0.292), CGPoint(x: 0.588, y: 0.238), CGPoint(x: 0.630, y: 0.165)]),
    Pose(name: "land", bodyYOffset: -10, scaleX: 1.06, scaleY: 0.90, legAlpha: 1.0,
         leftLeg: [CGPoint(x: 0.445, y: 0.292), CGPoint(x: 0.405, y: 0.235), CGPoint(x: 0.425, y: 0.160)],
         rightLeg: [CGPoint(x: 0.555, y: 0.292), CGPoint(x: 0.595, y: 0.235), CGPoint(x: 0.575, y: 0.160)]),
    Pose(name: "settle", bodyYOffset: 3, scaleX: 0.99, scaleY: 1.01, legAlpha: 1.0,
         leftLeg: [CGPoint(x: 0.445, y: 0.292), CGPoint(x: 0.438, y: 0.225), CGPoint(x: 0.425, y: 0.150)],
         rightLeg: [CGPoint(x: 0.555, y: 0.292), CGPoint(x: 0.562, y: 0.225), CGPoint(x: 0.575, y: 0.150)])
]

var frames: [NSImage] = []
for (index, pose) in poses.enumerated() {
    let frame = renderFrame(pose: pose)
    frames.append(frame)
    let url = outDir.appendingPathComponent(String(format: "frame-%02d-%@.png", index, pose.name))
    try savePNG(frame, to: url)
}

let thumb: CGFloat = 192
let padding: CGFloat = 24
let sheetSize = CGSize(width: padding * 2 + thumb * CGFloat(frames.count),
                       height: padding * 2 + thumb)
let sheet = NSImage(size: sheetSize)
sheet.lockFocus()
NSColor(srgbRed: 0.12, green: 0.13, blue: 0.16, alpha: 1).setFill()
CGRect(origin: .zero, size: sheetSize).fill()
for (index, frame) in frames.enumerated() {
    let rect = CGRect(x: padding + CGFloat(index) * thumb, y: padding, width: thumb, height: thumb)
    drawChecker(in: rect)
    NSGraphicsContext.current?.imageInterpolation = .none
    frame.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
}
sheet.unlockFocus()
try savePNG(sheet, to: sheetURL)
saveGIF(frames, to: gifURL)

print("已输出帧目录：\(outDir.path)")
print("已输出预览图：\(sheetURL.path)")
print("已输出 GIF：\(gifURL.path)")

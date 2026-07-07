import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let skinURL = root.appendingPathComponent("Resources/agent-pet-skin.png")
let outputURL = root.appendingPathComponent("design-previews/task-complete-leg-bend-runtime-size.png")
let noCutOutputURL = root.appendingPathComponent("design-previews/task-complete-leg-bend-runtime-size-no-cut.png")

guard let skin = NSImage(contentsOf: skinURL) else {
    fatalError("无法读取皮肤资源：\(skinURL.path)")
}

let canvasSize = CGSize(width: 260, height: 182)
let iconSize: CGFloat = 90
let bodyInsetRatio: CGFloat = 0.05
let frameGap: CGFloat = 10
let rowGap: CGFloat = 18
let zoom: CGFloat = 3
let frameCount = 6
let sheetSize = CGSize(
    width: CGFloat(frameCount) * canvasSize.width + CGFloat(frameCount - 1) * frameGap,
    height: canvasSize.height + rowGap + iconSize * zoom
)

let orange = NSColor(srgbRed: 0xF0 / 255.0, green: 0x52 / 255.0, blue: 0x22 / 255.0, alpha: 1.0)
let orangeDark = NSColor(srgbRed: 0x96 / 255.0, green: 0x2F / 255.0, blue: 0x15 / 255.0, alpha: 1.0)
let face = NSColor(srgbRed: 0.36, green: 0.10, blue: 0.05, alpha: 1)
let bgA = NSColor(srgbRed: 0.18, green: 0.19, blue: 0.22, alpha: 1)
let bgB = NSColor(srgbRed: 0.25, green: 0.26, blue: 0.30, alpha: 1)

struct RuntimeFrame {
    let phase: Int
    let jumpY: CGFloat
}

let frames = [
    RuntimeFrame(phase: 1, jumpY: -iconSize * 0.05),
    RuntimeFrame(phase: 2, jumpY: iconSize * 0.18),
    RuntimeFrame(phase: 3, jumpY: iconSize * 0.42),
    RuntimeFrame(phase: 4, jumpY: 0),
    RuntimeFrame(phase: 5, jumpY: iconSize * 0.20),
    RuntimeFrame(phase: 0, jumpY: 0),
]

func drawChecker(in rect: CGRect, cell: CGFloat = 8) {
    var y = rect.minY
    var row = 0
    while y < rect.maxY {
        var x = rect.minX
        var col = 0
        while x < rect.maxX {
            ((row + col).isMultiple(of: 2) ? bgA : bgB).setFill()
            CGRect(x: x, y: y, width: cell, height: cell).fill()
            x += cell
            col += 1
        }
        y += cell
        row += 1
    }
}

func aspectFitRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
    let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
    let width = imageSize.width * scale
    let height = imageSize.height * scale
    return CGRect(x: bounds.midX - width / 2,
                  y: bounds.midY - height / 2,
                  width: width,
                  height: height)
}

func point(in rect: CGRect, normalized: CGPoint) -> CGPoint {
    CGPoint(x: rect.minX + rect.width * normalized.x,
            y: rect.minY + rect.height * normalized.y)
}

func legPoses(phase: Int) -> [[CGPoint]] {
    switch phase {
    case 1:
        return [
            [CGPoint(x: 0.445, y: 0.292), CGPoint(x: 0.405, y: 0.235), CGPoint(x: 0.435, y: 0.165)],
            [CGPoint(x: 0.555, y: 0.292), CGPoint(x: 0.595, y: 0.235), CGPoint(x: 0.565, y: 0.165)]
        ]
    case 2:
        return [
            [CGPoint(x: 0.445, y: 0.292), CGPoint(x: 0.430, y: 0.220), CGPoint(x: 0.410, y: 0.145)],
            [CGPoint(x: 0.555, y: 0.292), CGPoint(x: 0.570, y: 0.220), CGPoint(x: 0.590, y: 0.145)]
        ]
    case 3:
        return [
            [CGPoint(x: 0.445, y: 0.292), CGPoint(x: 0.412, y: 0.238), CGPoint(x: 0.370, y: 0.165)],
            [CGPoint(x: 0.555, y: 0.292), CGPoint(x: 0.588, y: 0.238), CGPoint(x: 0.630, y: 0.165)]
        ]
    case 4:
        return [
            [CGPoint(x: 0.445, y: 0.292), CGPoint(x: 0.405, y: 0.235), CGPoint(x: 0.425, y: 0.160)],
            [CGPoint(x: 0.555, y: 0.292), CGPoint(x: 0.595, y: 0.235), CGPoint(x: 0.575, y: 0.160)]
        ]
    case 5:
        return [
            [CGPoint(x: 0.445, y: 0.292), CGPoint(x: 0.438, y: 0.225), CGPoint(x: 0.425, y: 0.150)],
            [CGPoint(x: 0.555, y: 0.292), CGPoint(x: 0.562, y: 0.225), CGPoint(x: 0.575, y: 0.150)]
        ]
    default:
        return []
    }
}

func clearOriginalLegs(_ ctx: CGContext, in rect: CGRect) {
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
        ctx.fill(CGRect(x: rect.minX + rect.width * region.minX,
                        y: rect.minY + rect.height * region.minY,
                        width: rect.width * region.width,
                        height: rect.height * region.height).integral)
    }
    ctx.restoreGState()
}

func drawSegment(_ ctx: CGContext, points: [CGPoint], color: NSColor, width: CGFloat) {
    guard points.count >= 2 else { return }
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

func drawLeg(_ ctx: CGContext, points: [CGPoint], bodySize: CGSize) {
    guard points.count >= 2, let foot = points.last else { return }
    let unit = min(bodySize.width, bodySize.height)
    let shadowOffset = CGSize(width: unit * 0.009, height: -unit * 0.011)
    drawSegment(ctx,
                points: points.map { CGPoint(x: $0.x + shadowOffset.width, y: $0.y + shadowOffset.height) },
                color: orangeDark,
                width: unit * 0.042)
    drawSegment(ctx, points: points, color: orange, width: unit * 0.033)

    let prev = points[points.count - 2]
    let footWidth = unit * 0.078
    let footHeight = unit * 0.036
    let leansRight = foot.x >= prev.x
    let footRect = CGRect(x: foot.x - (leansRight ? footWidth * 0.28 : footWidth * 0.72),
                          y: foot.y - footHeight * 0.45,
                          width: footWidth,
                          height: footHeight).integral
    ctx.setFillColor(orangeDark.cgColor)
    ctx.fill(footRect.offsetBy(dx: shadowOffset.width, dy: shadowOffset.height))
    ctx.setFillColor(orange.cgColor)
    ctx.fill(footRect)
}

func drawHappyFace(_ ctx: CGContext, in rect: CGRect) {
    let unit = min(rect.width, rect.height)
    let eyeSize = CGSize(width: unit * 0.028, height: unit * 0.067)
    let radius = eyeSize.width * 1.1
    let centers = [
        CGPoint(x: rect.minX + rect.width * 0.405, y: rect.minY + rect.height * 0.523),
        CGPoint(x: rect.minX + rect.width * 0.595, y: rect.minY + rect.height * 0.523),
    ]
    ctx.setStrokeColor(face.cgColor)
    ctx.setFillColor(face.cgColor)
    ctx.setLineCap(.round)
    ctx.setLineWidth(unit * 0.014)
    for center in centers {
        ctx.beginPath()
        ctx.addArc(center: CGPoint(x: center.x, y: center.y - radius * 0.35),
                   radius: radius,
                   startAngle: .pi * 0.18,
                   endAngle: .pi * 0.82,
                   clockwise: false)
        ctx.strokePath()
    }
    let mouthCenter = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.418)
    ctx.fillEllipse(in: CGRect(x: mouthCenter.x - unit * 0.058,
                               y: mouthCenter.y - unit * 0.034 * 0.75,
                               width: unit * 0.116,
                               height: unit * 0.068 * 0.75))
}

func drawPet(frame: RuntimeFrame, iconFrame: CGRect, cutsOriginalLegs: Bool) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let skinBounds = iconFrame.insetBy(dx: iconFrame.width * bodyInsetRatio, dy: iconFrame.height * bodyInsetRatio)
    let bodyRect = aspectFitRect(imageSize: skin.size, in: skinBounds)
    NSGraphicsContext.current?.imageInterpolation = .none
    skin.draw(in: bodyRect, from: .zero, operation: .sourceOver, fraction: 1)
    if frame.phase > 0 {
        if cutsOriginalLegs {
            clearOriginalLegs(ctx, in: bodyRect)
        }
        for pose in legPoses(phase: frame.phase) {
            drawLeg(ctx, points: pose.map { point(in: bodyRect, normalized: $0) }, bodySize: bodyRect.size)
        }
    }
    drawHappyFace(ctx, in: bodyRect)
}

func renderSheet(cutsOriginalLegs: Bool) -> NSImage {
    let image = NSImage(size: sheetSize)
    image.lockFocus()
    NSColor(srgbRed: 0.12, green: 0.13, blue: 0.16, alpha: 1).setFill()
    CGRect(origin: .zero, size: sheetSize).fill()

    for (index, frame) in frames.enumerated() {
        let x = CGFloat(index) * (canvasSize.width + frameGap)
        let canvas = CGRect(x: x, y: iconSize * zoom + rowGap, width: canvasSize.width, height: canvasSize.height)
        drawChecker(in: canvas)
        let iconFrame = CGRect(x: canvas.minX + (canvas.width - iconSize) / 2,
                               y: canvas.minY + frame.jumpY,
                               width: iconSize,
                               height: iconSize)
        drawPet(frame: frame, iconFrame: iconFrame, cutsOriginalLegs: cutsOriginalLegs)

        let zoomCanvas = CGRect(x: x + (canvasSize.width - iconSize * zoom) / 2,
                                y: 0,
                                width: iconSize * zoom,
                                height: iconSize * zoom)
        drawChecker(in: zoomCanvas, cell: 12)
        let zoomIcon = CGRect(x: zoomCanvas.minX,
                              y: zoomCanvas.minY + frame.jumpY * zoom,
                              width: iconSize * zoom,
                              height: iconSize * zoom)
        drawPet(frame: frame, iconFrame: zoomIcon, cutsOriginalLegs: cutsOriginalLegs)
    }
    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("PNG 编码失败")
    }
    try png.write(to: url, options: .atomic)
}

try writePNG(renderSheet(cutsOriginalLegs: true), to: outputURL)
try writePNG(renderSheet(cutsOriginalLegs: false), to: noCutOutputURL)
print("已输出：\(outputURL.path)")
print("已输出：\(noCutOutputURL.path)")

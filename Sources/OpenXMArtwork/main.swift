import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Original, code-drawn OpenXM identity. No fonts, downloads, or raster source needed.
func icon(size: Int) -> CGImage {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 25, color: CGColor(gray: 0, alpha: 0.22))
    context.setFillColor(CGColor(red: 0.065, green: 0.22, blue: 0.18, alpha: 1))
    context.addPath(CGPath(roundedRect: tile, cornerWidth: 184, cornerHeight: 184, transform: nil))
    context.fillPath()
    context.setShadow(offset: .zero, blur: 0)
    context.setStrokeColor(CGColor(red: 0.66, green: 0.94, blue: 0.79, alpha: 1))
    context.setLineWidth(58); context.setLineCap(.round)
    context.addArc(center: CGPoint(x: 512, y: 490), radius: 222, startAngle: 0, endAngle: .pi, clockwise: false)
    context.strokePath()
    for x in [290.0, 734.0] {
        context.move(to: CGPoint(x: x, y: 490)); context.addLine(to: CGPoint(x: x, y: 335)); context.strokePath()
    }
    context.setLineWidth(43)
    for (x, low, high) in [(439.0, 350.0, 490.0), (573.0, 295.0, 550.0)] {
        context.move(to: CGPoint(x: x, y: low)); context.addLine(to: CGPoint(x: x, y: high)); context.strokePath()
    }
    return context.makeImage()!
}
let args = CommandLine.arguments
guard args.count == 3, args[1] == "icon" else {
    fputs("Usage: OpenXMArtwork icon <output.iconset>\n", stderr); exit(2)
}
let output = URL(fileURLWithPath: args[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let url = output.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
        CGImageDestinationAddImage(destination, icon(size: points * scale), nil)
        guard CGImageDestinationFinalize(destination) else { exit(1) }
    }
}
print("Wrote \(output.path)")

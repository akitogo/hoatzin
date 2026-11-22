// Builds Resources/AppIcon.icns from the artwork in Resources/AppIcon-source.png.
//
//   swift scripts/make-icon.swift <source.png> <output.icns>
//
// The artwork is a rounded square on a light background. The script finds the square, masks it
// with the macOS icon shape (so the corners are transparent instead of white), places it on
// Apple's icon grid (an 824 pt body on a 1024 pt canvas) with a soft shadow, and writes every
// size from 16 to 1024 px into an .icns via iconutil.

import AppKit

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { die("usage: make-icon.swift <source.png> <output.icns>") }
guard let source = NSImage(contentsOfFile: arguments[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    die("can't read \(arguments[1])")
}

// 1. Find the artwork: the box around pixels that are clearly not background (white or the
//    light shadow). Rows and columns with only a few such pixels are noise.
let width = source.width, height = source.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
pixels.withUnsafeMutableBytes { buffer in
    let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
}
func isArt(_ x: Int, _ y: Int) -> Bool {
    let i = (y * width + x) * 4
    return min(pixels[i], pixels[i + 1], pixels[i + 2]) < 200
}
var rowCounts = [Int](repeating: 0, count: height), columnCounts = [Int](repeating: 0, count: width)
for y in 0..<height { for x in 0..<width where isArt(x, y) { rowCounts[y] += 1; columnCounts[x] += 1 } }
let minimum = max(4, width / 50)
guard let top = rowCounts.firstIndex(where: { $0 >= minimum }), let bottom = rowCounts.lastIndex(where: { $0 >= minimum }),
      let left = columnCounts.firstIndex(where: { $0 >= minimum }), let right = columnCounts.lastIndex(where: { $0 >= minimum })
else { die("no artwork found in \(arguments[1])") }
let side = max(right - left, bottom - top) + 1
let box = CGRect(x: (left + right + 1 - side) / 2, y: (top + bottom + 1 - side) / 2, width: side, height: side)
guard let artwork = source.cropping(to: box) else { die("can't crop the artwork") }
print("Icon artwork: \(side)×\(side) px at \(Int(box.minX)),\(Int(box.minY)) in a \(width)×\(height) image")

// 2. The icon shape: a superellipse. n = 4 matches the artwork's own corners (measured: about
//    4 px off on a 1049 px square). It sits a little inside the artwork's edge, so no light edge
//    pixels survive.
func iconShape(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let n = 4.0, steps = 720
    for step in 0...steps {
        let t = Double(step) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + rect.width / 2 * CGFloat(copysign(pow(abs(c), 2 / n), c))
        let y = rect.midY + rect.height / 2 * CGFloat(copysign(pow(abs(s), 2 / n), s))
        step == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    let body = CGRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let shape = iconShape(in: body.insetBy(dx: body.width * 0.012, dy: body.height * 0.012))
    // Soft shadow under the body, as on other macOS icons.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -s * 0.010), blur: s * 0.024, color: CGColor(gray: 0, alpha: 0.32))
    context.addPath(shape)
    context.setFillColor(CGColor(gray: 0.08, alpha: 1))
    context.fillPath()
    context.restoreGState()
    // The artwork, clipped to the shape.
    context.addPath(shape)
    context.clip()
    context.draw(artwork, in: body)
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    return bitmap.representation(using: .png, properties: [:])!
}

// 3. All sizes into an .iconset, then iconutil.
let output = URL(fileURLWithPath: arguments[2])
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { die("iconutil failed") }
print("Wrote \(output.path)")

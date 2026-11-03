// Renders the StatLine app icon: two CPU/RAM bars (like the Mini Bars style) beside
// download/upload arrows, on a slate plate that follows the macOS icon grid.
//
// Usage: swift design/render.swift <repo-root> <out-dir>
//   Writes size-{16..1024}.png to <out-dir>, docs/icon.png (256px) to the repo,
//   and a light/dark review sheet to build/icon-review.png (git-ignored).
import AppKit

let root = CommandLine.arguments[1]
let out = CommandLine.arguments[2]

func render(_ size: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    image.addRepresentation(bitmap)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)!
    let k = CGFloat(size) / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: k, y: k)   // draw in 1024-unit coordinates

    // Plate: 824pt rounded rect centred on the 1024 canvas (standard macOS app icon grid).
    let plate = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 20 * k            // shadows ignore the CTM, so scale them by hand
    shadow.shadowOffset = NSSize(width: 0, height: -12 * k)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.darkGray.setFill()
    plate.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(calibratedRed: 0.25, green: 0.30, blue: 0.37, alpha: 1),
               ending: NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.19, alpha: 1))!.draw(in: plate, angle: 90)
    NSColor(calibratedWhite: 1, alpha: 0.16).setStroke()
    plate.lineWidth = 3
    plate.stroke()

    // Mark: CPU and RAM bars, then ↓ download and ↑ upload arrows.
    NSColor(calibratedRed: 0.88, green: 0.95, blue: 0.95, alpha: 1).setFill()
    NSRect(x: 270, y: 330, width: 88, height: 250).fill()
    NSRect(x: 402, y: 330, width: 88, height: 360).fill()
    func arrow(centerX x: CGFloat, centerY y: CGFloat, up: Bool) {
        let pts: [CGPoint] = [CGPoint(x: -32, y: 96), CGPoint(x: 32, y: 96), CGPoint(x: 32, y: -8), CGPoint(x: 80, y: -8),
                              CGPoint(x: 0, y: -96), CGPoint(x: -80, y: -8), CGPoint(x: -32, y: -8)]
        let p = NSBezierPath()
        for (i, q) in pts.enumerated() {
            let v = CGPoint(x: x + q.x, y: y + (up ? -q.y : q.y))
            if i == 0 { p.move(to: v) } else { p.line(to: v) }
        }
        p.close()
        p.fill()
    }
    arrow(centerX: 616, centerY: 512, up: false)
    arrow(centerX: 770, centerY: 512, up: true)

    NSGraphicsContext.restoreGraphicsState()
    return image
}

func save(_ image: NSImage, _ path: String) {
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

for s in [16, 32, 64, 128, 256, 512, 1024] { save(render(s), "\(out)/size-\(s).png") }
save(render(256), "\(root)/docs/icon.png")

// Review sheet: each size on a light and a dark background.
let sheet = NSImage(size: NSSize(width: 1504, height: 2260))
sheet.lockFocus()
for (row, bg) in [NSColor(calibratedWhite: 0.94, alpha: 1), NSColor(calibratedWhite: 0.07, alpha: 1)].enumerated() {
    let y = CGFloat(row * 1130)
    bg.setFill()
    NSRect(x: 0, y: y, width: 1504, height: 1130).fill()
    for (s, x) in [(1024, 16), (256, 1060), (64, 1340), (32, 1420), (16, 1470)] {
        render(s).draw(in: NSRect(x: CGFloat(x), y: y + 55, width: CGFloat(s), height: CGFloat(s)))
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                                    .foregroundColor: row == 0 ? NSColor.black : NSColor.white]
        ("\(s)" as NSString).draw(at: NSPoint(x: CGFloat(x), y: y + 20), withAttributes: attrs)
    }
}
sheet.unlockFocus()
try? FileManager.default.createDirectory(atPath: "\(root)/build", withIntermediateDirectories: true)
save(sheet, "\(root)/build/icon-review.png")

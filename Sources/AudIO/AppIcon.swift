import Cocoa

// App icon: a squircle split along a "/" into a warm output half (speaker) and a cool
// input half (microphone). Drawn from plain shapes, since SF Symbols' licence doesn't
// allow them in app icons.
enum AppIcon {
    /// Layout is on Apple's 1024pt icon grid: an 824pt body with a 100pt margin for the shadow
    private static let grid: CGFloat = 1024
    private static let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    private static let cornerRadius: CGFloat = 185

    static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let scale = NSAffineTransform()
            scale.scale(by: size / grid)
            scale.concat()
            draw()
            return true
        }
    }

    private static func draw() {
        let shape = NSBezierPath(roundedRect: body, xRadius: cornerRadius, yRadius: cornerRadius)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.shadowBlurRadius = 24
        shadow.set()
        NSColor.black.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()

        // Output half (top left), then input half (bottom right) below the "/"
        NSGradient(starting: color(0xFF8A4C), ending: color(0xFF4F6D))!.draw(in: body, angle: -45)
        let inputHalf = NSBezierPath()
        inputHalf.move(to: NSPoint(x: body.minX - 50, y: body.minY - 50))
        inputHalf.line(to: NSPoint(x: body.maxX + 50, y: body.maxY + 50))
        inputHalf.line(to: NSPoint(x: body.maxX + 50, y: body.minY - 50))
        inputHalf.close()
        NSGraphicsContext.saveGraphicsState()
        inputHalf.addClip()
        NSGradient(starting: color(0x4D7CFF), ending: color(0x6A3DF0))!.draw(in: body, angle: -45)
        NSGraphicsContext.restoreGraphicsState()

        let slash = NSBezierPath()
        slash.move(to: NSPoint(x: body.minX, y: body.minY))
        slash.line(to: NSPoint(x: body.maxX, y: body.maxY))
        slash.lineWidth = 22
        NSColor.white.withAlphaComponent(0.9).setStroke()
        slash.stroke()

        drawSpeaker(center: NSPoint(x: body.minX + 280, y: body.maxY - 270), size: 290)
        drawMicrophone(center: NSPoint(x: body.maxX - 270, y: body.minY + 250), size: 300)

        // Soft highlight across the top
        NSGradient(starting: NSColor.white.withAlphaComponent(0.18), ending: NSColor.white.withAlphaComponent(0))!
            .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawSpeaker(center c: NSPoint, size s: CGFloat) {
        NSColor.white.set()
        let boxW = s * 0.2, boxH = s * 0.34
        let left = c.x - s * 0.42
        NSBezierPath(roundedRect: NSRect(x: left, y: c.y - boxH / 2, width: boxW, height: boxH),
                     xRadius: s * 0.04, yRadius: s * 0.04).fill()

        let cone = NSBezierPath()
        cone.move(to: NSPoint(x: left + boxW - 2, y: c.y - boxH / 2))
        cone.line(to: NSPoint(x: left + boxW + s * 0.26, y: c.y - s * 0.4))
        cone.line(to: NSPoint(x: left + boxW + s * 0.26, y: c.y + s * 0.4))
        cone.line(to: NSPoint(x: left + boxW - 2, y: c.y + boxH / 2))
        cone.close()
        cone.lineJoinStyle = .round
        cone.lineWidth = s * 0.05
        cone.fill()
        cone.stroke()

        let origin = NSPoint(x: left + boxW + s * 0.2, y: c.y)
        for radius in [s * 0.34, s * 0.54] {
            let wave = NSBezierPath()
            wave.appendArc(withCenter: origin, radius: radius, startAngle: -42, endAngle: 42)
            wave.lineWidth = s * 0.085
            wave.lineCapStyle = .round
            wave.stroke()
        }
    }

    private static func drawMicrophone(center c: NSPoint, size s: CGFloat) {
        NSColor.white.set()
        let capW = s * 0.34, capH = s * 0.56
        let capsule = NSRect(x: c.x - capW / 2, y: c.y - s * 0.05, width: capW, height: capH)
        NSBezierPath(roundedRect: capsule, xRadius: capW / 2, yRadius: capW / 2).fill()

        let cradleCenter = NSPoint(x: c.x, y: capsule.minY + capW / 2)
        let stand = NSBezierPath()
        stand.appendArc(withCenter: cradleCenter, radius: s * 0.3, startAngle: 180, endAngle: 360)
        stand.move(to: NSPoint(x: c.x, y: cradleCenter.y - s * 0.3))
        stand.line(to: NSPoint(x: c.x, y: cradleCenter.y - s * 0.46))
        stand.move(to: NSPoint(x: c.x - s * 0.17, y: cradleCenter.y - s * 0.46))
        stand.line(to: NSPoint(x: c.x + s * 0.17, y: cradleCenter.y - s * 0.46))
        stand.lineWidth = s * 0.075
        stand.lineCapStyle = .round
        stand.stroke()
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }

    /// Writes the PNGs that `iconutil` turns into AppIcon.icns (used by scripts/build.sh)
    static func writeIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                try png(pixels: points * scale).write(to: directory.appendingPathComponent(name))
            }
        }
    }

    private static func png(pixels: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image(size: CGFloat(pixels)).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
}

import AppKit
import ImagePlayground
import Vision

/// Turns Tony's headshot into a cartoon with Image Playground (on-device).
enum CartoonMaker {
    @MainActor
    static func cartoon(from photo: NSImage) async -> NSImage? {
        guard let cg = photo.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        do {
            let creator = try await ImageCreator()
            guard creator.availableStyles.contains(.animation) else { return nil }
            let concepts: [ImagePlaygroundConcept] = [
                .image(cg),
                .text("A friendly smiling portrait, head and shoulders, wearing a suit, plain soft background"),
            ]
            for try await created in creator.images(for: concepts, style: .animation, limit: 1) {
                let cg = created.cgImage
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        } catch {
            FileHandle.standardError.write(Data("Image Playground: \(error)\n".utf8))
        }
        return nil
    }
}

/// Draws the app icon: cartoon Tony in a gold medallion on a pedestal, on stage.
enum IconRenderer {
    static func icon(face: NSImage?, isCartoon: Bool) -> NSImage {
        let size: CGFloat = 1024
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let ctx = NSGraphicsContext.current!.cgContext
        let space = CGColorSpaceCreateDeviceRGB()
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { NSColor(calibratedRed: r, green: g, blue: b, alpha: a).cgColor }
        func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
            CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
        }

        // macOS icon grid: 824pt rounded square centred in 1024.
        let inset: CGFloat = 100
        let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        let body = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
        ctx.addPath(body); ctx.setFillColor(rgb(0, 0, 0)); ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(body); ctx.clip()
        // Velvet curtain
        ctx.drawLinearGradient(gradient([rgb(0.62, 0.05, 0.12), rgb(0.30, 0.01, 0.06)]),
                               start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
        // Curtain folds
        for i in 0..<9 {
            let x = rect.minX + CGFloat(i) * rect.width / 8
            ctx.drawLinearGradient(gradient([rgb(0, 0, 0, 0), rgb(0, 0, 0, 0.22), rgb(0, 0, 0, 0)], [0, 0.5, 1]),
                                   start: CGPoint(x: x - 46, y: 0), end: CGPoint(x: x + 46, y: 0), options: [])
        }
        // Spotlight
        ctx.drawRadialGradient(gradient([rgb(1, 0.93, 0.75, 0.55), rgb(1, 0.9, 0.7, 0)]),
                               startCenter: CGPoint(x: size / 2, y: 560), startRadius: 0,
                               endCenter: CGPoint(x: size / 2, y: 560), endRadius: 400, options: [])
        // Stage floor
        ctx.setFillColor(rgb(0.12, 0.04, 0.05))
        ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 150))
        ctx.restoreGState()

        let gold = gradient([rgb(1.0, 0.90, 0.55), rgb(0.93, 0.70, 0.22), rgb(0.62, 0.42, 0.08)], [0, 0.5, 1])
        let cx = size / 2

        // Pedestal
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: rgb(0, 0, 0, 0.5))
        let base = CGPath(roundedRect: CGRect(x: cx - 190, y: 196, width: 380, height: 70), cornerWidth: 14, cornerHeight: 14, transform: nil)
        ctx.addPath(base); ctx.setFillColor(rgb(0.08, 0.08, 0.09)); ctx.fillPath()
        let stem = CGMutablePath()
        stem.move(to: CGPoint(x: cx - 120, y: 266)); stem.addLine(to: CGPoint(x: cx + 120, y: 266))
        stem.addLine(to: CGPoint(x: cx + 60, y: 330)); stem.addLine(to: CGPoint(x: cx - 60, y: 330)); stem.closeSubpath()
        ctx.addPath(stem); ctx.clip()
        ctx.drawLinearGradient(gold, start: CGPoint(x: cx - 120, y: 0), end: CGPoint(x: cx + 120, y: 0), options: [])
        ctx.restoreGState()

        // Medallion
        let r: CGFloat = 250
        let center = CGPoint(x: cx, y: 590)
        let outer = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: rgb(0, 0, 0, 0.55))
        ctx.addEllipse(in: outer); ctx.setFillColor(rgb(0.8, 0.6, 0.2)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addEllipse(in: outer); ctx.clip()
        ctx.drawLinearGradient(gold, start: CGPoint(x: outer.minX, y: outer.maxY), end: CGPoint(x: outer.maxX, y: outer.minY), options: [])
        ctx.restoreGState()
        // Engraved inner ring
        ctx.setStrokeColor(rgb(0.55, 0.36, 0.05, 0.8)); ctx.setLineWidth(6)
        ctx.strokeEllipse(in: outer.insetBy(dx: 22, dy: 22))

        // Tony
        let faceRect = outer.insetBy(dx: 40, dy: 40)
        ctx.saveGState()
        ctx.addEllipse(in: faceRect); ctx.clip()
        ctx.setFillColor(rgb(0.98, 0.95, 0.88)); ctx.fill(faceRect)
        if let face, let cg = FaceCrop.portrait(face) { ctx.draw(cg, in: faceRect) }
        ctx.restoreGState()
        ctx.setStrokeColor(rgb(1, 0.92, 0.6)); ctx.setLineWidth(5)
        ctx.strokeEllipse(in: faceRect)

        // Sparkles
        for (x, y, s) in [(250.0, 800.0, 34.0), (790.0, 760.0, 26.0), (720.0, 860.0, 18.0), (300.0, 420.0, 20.0)] {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x, y: y + s)); p.addQuadCurve(to: CGPoint(x: x + s, y: y), control: CGPoint(x: x, y: y))
            p.addQuadCurve(to: CGPoint(x: x, y: y - s), control: CGPoint(x: x, y: y))
            p.addQuadCurve(to: CGPoint(x: x - s, y: y), control: CGPoint(x: x, y: y))
            p.addQuadCurve(to: CGPoint(x: x, y: y + s), control: CGPoint(x: x, y: y))
            ctx.addPath(p); ctx.setFillColor(rgb(1, 0.92, 0.6, 0.95)); ctx.fillPath()
        }

        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        return image
    }

    static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Finds Tony's face with Vision and returns a square head-and-shoulders crop,
/// however Image Playground happened to frame the picture.
enum FaceCrop {
    static func portrait(_ image: NSImage, zoom: CGFloat = 2.0) -> CGImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: cg).perform([request])
        guard let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width })?.boundingBox else {
            let side = min(w, h)
            return cg.cropping(to: CGRect(x: (w - side) / 2, y: 0, width: side, height: side))
        }
        // Vision uses a bottom-left origin; CGImage cropping uses top-left.
        let faceW = face.width * w, faceH = face.height * h
        let centerX = face.midX * w
        let centerY = (1 - face.midY) * h - faceH * 0.12   // nudge up to include hair
        let side = min(max(faceW, faceH) * zoom, min(w, h))
        let x = min(max(centerX - side / 2, 0), w - side)
        let y = min(max(centerY - side / 2, 0), h - side)
        return cg.cropping(to: CGRect(x: x, y: y, width: side, height: side))
    }
}

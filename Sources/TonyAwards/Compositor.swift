import AppKit
import Vision
import CoreImage

/// Builds Daily Tony pictures: Paul's caricature, exactly as drawn, placed on a generated
/// backdrop and holding a generated prop. Apple's image model only draws scenes and objects
/// (which it does well); it never redraws Tony's face.
enum Compositor {
    private static let ciContext = CIContext()

    /// Where the raised (waving) hand is in the caricature, as fractions of the image (top-left origin).
    /// Detected with Vision when possible; this is the fallback for Paul's drawing.
    static let fallbackHand = CGPoint(x: 0.296, y: 0.47)

    static func compose(caricature: NSImage, backdrop: NSImage?, prop: NSImage?, propSymbol: String, tint: NSColor) -> NSImage? {
        guard let tonyCG = caricature.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let tonyCut = cutout(tonyCG) else { return nil }
        let size: CGFloat = 1024
        let canvas = CGRect(x: 0, y: 0, width: size, height: size)
        guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // 1. Backdrop (generated scene, or a soft spotlight gradient).
        if let bg = backdrop?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ctx.draw(bg, in: aspectFill(CGSize(width: bg.width, height: bg.height), in: canvas))
            // Gentle vignette so Tony pops.
            let vignette = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.withAlphaComponent(0.35).cgColor] as CFArray,
                                      locations: [0.55, 1])!
            ctx.drawRadialGradient(vignette, startCenter: CGPoint(x: size / 2, y: size / 2), startRadius: 0,
                                   endCenter: CGPoint(x: size / 2, y: size / 2), endRadius: size * 0.75, options: [.drawsAfterEndLocation])
        } else {
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [tint.blended(withFraction: 0.55, of: .white)!.cgColor, tint.cgColor] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: size * 0.45, y: size * 0.65), startRadius: 0,
                                   endCenter: CGPoint(x: size * 0.45, y: size * 0.65), endRadius: size * 0.9, options: [.drawsAfterEndLocation])
        }

        // 2. Tony, full height, a little left of centre to leave room for the prop.
        let tw = CGFloat(tonyCut.width), th = CGFloat(tonyCut.height)
        let scale = size * 0.97 / th
        let tonyRect = CGRect(x: size * 0.57 - tw * scale / 2, y: 0, width: tw * scale, height: th * scale)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 22, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.draw(tonyCut, in: tonyRect)
        ctx.restoreGState()

        // 3. The prop, held up in his raised hand.
        let hand = handPoint(tonyCG)
        let handInCanvas = CGPoint(x: tonyRect.minX + hand.x * tonyRect.width,
                                   y: tonyRect.maxY - hand.y * tonyRect.height)   // flip to bottom-left origin
        let propSide = size * 0.27
        var propImage: CGImage? = prop?.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap { cutout($0, cropToSubject: true) }
        if propImage == nil { propImage = symbolImage(propSymbol, tint: tint, side: propSide) }
        if let p = propImage {
            let pw = CGFloat(p.width), ph = CGFloat(p.height)
            let s = propSide / max(pw, ph)
            let rect = CGRect(x: handInCanvas.x - pw * s * 0.62, y: handInCanvas.y - ph * s * 0.12, width: pw * s, height: ph * s)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 14, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.draw(p, in: rect)
            ctx.restoreGState()
        }

        guard let out = ctx.makeImage() else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: size, height: size))
    }

    // MARK: Helpers

    /// Lifts the subject(s) off their background using Vision.
    static func cutout(_ image: CGImage, cropToSubject: Bool = false) -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil,
              let result = request.results?.first,
              let buffer = try? result.generateMaskedImage(ofInstances: result.allInstances, from: handler,
                                                           croppedToInstancesExtent: cropToSubject)
        else { return nil }
        let ci = CIImage(cvPixelBuffer: buffer)
        return ciContext.createCGImage(ci, from: ci.extent)
    }

    /// Finds the raised hand (highest wrist) with Vision's hand-pose detector.
    static func handPoint(_ image: CGImage) -> CGPoint {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let points = (request.results ?? []).compactMap { obs -> CGPoint? in
            guard let all = try? obs.recognizedPoints(.all) else { return nil }
            let good = all.values.filter { $0.confidence > 0.3 }
            guard !good.isEmpty else { return nil }
            // Top of the hand (fingertips) in top-left coordinates.
            let topY = 1 - (good.map(\.location.y).max() ?? 0)
            let x = good.map(\.location.x).reduce(0, +) / CGFloat(good.count)
            return CGPoint(x: x, y: topY)
        }
        return points.min { $0.y < $1.y } ?? fallbackHand
    }

    private static func symbolImage(_ name: String, tint: NSColor, side: CGFloat) -> CGImage? {
        let config = NSImage.SymbolConfiguration(pointSize: side * 0.7, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            tint.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4)).fill()
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 6, dy: 6)); ring.lineWidth = 8; ring.stroke()
            let s = symbol.size
            symbol.draw(in: CGRect(x: (side - s.width) / 2, y: (side - s.height) / 2, width: s.width, height: s.height))
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private static func aspectFill(_ s: CGSize, in r: CGRect) -> CGRect {
        let scale = max(r.width / s.width, r.height / s.height)
        let w = s.width * scale, h = s.height * scale
        return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }
}

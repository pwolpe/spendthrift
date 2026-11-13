import AppKit
import Vision

/// Small picture helpers.
enum IconRenderer {
    static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Finds Tony's face with Vision and returns a square head-and-shoulders crop,
/// however the picture happens to be framed.
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

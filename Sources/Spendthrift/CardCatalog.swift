import SwiftUI

/// The well-known cards, so a card can be called what its owner calls it and drawn so they know it
/// at a glance. This is general knowledge about card products (their names, the words their
/// statements print, the yearly fees they have charged, their colours), not anything about one
/// person. Nothing here is about benefits: the Cards pages take those from the statements alone.
///
/// The drawings are the app's own: a colour and a pattern in the spirit of the card, with no
/// issuer's logo or artwork copied.
enum CardCatalog {
    enum Pattern { case plain, waves, facets, frame, code, arcs, bands, rings, weave }

    struct Look {
        var top: Color
        var bottom: Color
        /// The pattern's own colour, laid over the face.
        var line: Color
        var pattern: Pattern
        var darkInk = false
    }

    struct Product: Identifiable {
        var id: String { title }
        /// What people call it: "Chase Sapphire Reserve".
        var title: String
        /// As printed on the card's face: "SAPPHIRE RESERVE".
        var face: String
        var issuer: String
        /// Words a statement prints that name this card and no other.
        var phrases: [String]
        /// Words that go with it but also with its siblings.
        var hints: [String] = []
        /// Yearly fees it has charged over the years.
        var fees: [Double] = []
        var look: Look
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }

    static let products: [Product] = [
        // Chase
        Product(title: "Chase Sapphire Reserve", face: "SAPPHIRE RESERVE", issuer: "Chase", phrases: ["sapphire reserve"], hints: ["ultimate rewards"], fees: [450, 550, 795],
                look: Look(top: rgb(0.06, 0.13, 0.31), bottom: rgb(0.02, 0.04, 0.13), line: rgb(0.38, 0.58, 0.95), pattern: .facets)),
        Product(title: "Chase Sapphire Preferred", face: "SAPPHIRE PREFERRED", issuer: "Chase", phrases: ["sapphire preferred"], hints: ["ultimate rewards"], fees: [95],
                look: Look(top: rgb(0.13, 0.33, 0.66), bottom: rgb(0.05, 0.15, 0.4), line: rgb(0.6, 0.78, 1.0), pattern: .waves)),
        Product(title: "Chase Freedom Unlimited", face: "FREEDOM UNLIMITED", issuer: "Chase", phrases: ["freedom unlimited"],
                look: Look(top: rgb(0.55, 0.68, 0.82), bottom: rgb(0.25, 0.4, 0.62), line: .white, pattern: .arcs)),
        Product(title: "Chase Freedom Flex", face: "FREEDOM FLEX", issuer: "Chase", phrases: ["freedom flex"],
                look: Look(top: rgb(0.42, 0.62, 0.86), bottom: rgb(0.16, 0.3, 0.6), line: .white, pattern: .arcs)),
        Product(title: "Prime Visa", face: "PRIME VISA", issuer: "Chase", phrases: ["prime visa", "amazon prime rewards", "amazon rewards visa"],
                look: Look(top: rgb(0.13, 0.19, 0.25), bottom: rgb(0.04, 0.07, 0.11), line: rgb(0.25, 0.75, 0.86), pattern: .bands)),
        Product(title: "Chase Ink Business Preferred", face: "INK BUSINESS PREFERRED", issuer: "Chase", phrases: ["ink business preferred"], fees: [95],
                look: Look(top: rgb(0.16, 0.2, 0.27), bottom: rgb(0.06, 0.08, 0.12), line: rgb(0.5, 0.6, 0.75), pattern: .weave)),
        // American Express
        Product(title: "Amex Platinum", face: "PLATINUM CARD", issuer: "American Express", phrases: ["platinum card"], hints: ["platinum"], fees: [450, 550, 695, 895],
                look: Look(top: rgb(0.88, 0.89, 0.91), bottom: rgb(0.6, 0.63, 0.68), line: rgb(0.3, 0.33, 0.38), pattern: .frame, darkInk: true)),
        Product(title: "Amex Gold", face: "GOLD CARD", issuer: "American Express", phrases: ["gold card"], hints: ["gold"], fees: [250, 325],
                look: Look(top: rgb(0.95, 0.83, 0.5), bottom: rgb(0.72, 0.55, 0.2), line: rgb(0.45, 0.32, 0.08), pattern: .frame, darkInk: true)),
        Product(title: "Amex Green", face: "GREEN CARD", issuer: "American Express", phrases: ["green card"], fees: [150],
                look: Look(top: rgb(0.45, 0.66, 0.52), bottom: rgb(0.2, 0.42, 0.3), line: rgb(0.08, 0.22, 0.14), pattern: .frame, darkInk: true)),
        Product(title: "Amex Blue Cash Preferred", face: "BLUE CASH PREFERRED", issuer: "American Express", phrases: ["blue cash preferred"], fees: [95],
                look: Look(top: rgb(0.2, 0.47, 0.8), bottom: rgb(0.07, 0.24, 0.55), line: .white, pattern: .frame)),
        Product(title: "Amex Blue Cash Everyday", face: "BLUE CASH EVERYDAY", issuer: "American Express", phrases: ["blue cash everyday"],
                look: Look(top: rgb(0.35, 0.62, 0.9), bottom: rgb(0.14, 0.36, 0.7), line: .white, pattern: .frame)),
        Product(title: "Delta SkyMiles Amex", face: "DELTA SKYMILES", issuer: "American Express", phrases: ["skymiles"],
                look: Look(top: rgb(0.14, 0.2, 0.4), bottom: rgb(0.05, 0.08, 0.2), line: rgb(0.85, 0.2, 0.25), pattern: .bands)),
        Product(title: "Hilton Honors Amex", face: "HILTON HONORS", issuer: "American Express", phrases: ["hilton honors"],
                look: Look(top: rgb(0.1, 0.22, 0.42), bottom: rgb(0.04, 0.1, 0.24), line: rgb(0.7, 0.8, 0.95), pattern: .arcs)),
        // Capital One
        Product(title: "Capital One Venture X", face: "VENTURE X", issuer: "Capital One", phrases: ["venture x"], fees: [395],
                look: Look(top: rgb(0.16, 0.19, 0.27), bottom: rgb(0.05, 0.06, 0.1), line: rgb(0.55, 0.62, 0.8), pattern: .bands)),
        Product(title: "Capital One Venture", face: "VENTURE", issuer: "Capital One", phrases: ["venture"], fees: [95],
                look: Look(top: rgb(0.12, 0.3, 0.52), bottom: rgb(0.04, 0.12, 0.3), line: rgb(0.6, 0.78, 1.0), pattern: .bands)),
        Product(title: "Capital One Quicksilver", face: "QUICKSILVER", issuer: "Capital One", phrases: ["quicksilver"],
                look: Look(top: rgb(0.8, 0.82, 0.85), bottom: rgb(0.48, 0.51, 0.56), line: .white, pattern: .bands, darkInk: true)),
        Product(title: "Capital One Savor", face: "SAVOR", issuer: "Capital One", phrases: ["savorone", "savor"],
                look: Look(top: rgb(0.78, 0.45, 0.24), bottom: rgb(0.45, 0.2, 0.1), line: rgb(1.0, 0.8, 0.6), pattern: .bands)),
        // Citi
        Product(title: "Citi Double Cash", face: "DOUBLE CASH", issuer: "Citi", phrases: ["double cash"],
                look: Look(top: rgb(0.16, 0.5, 0.62), bottom: rgb(0.06, 0.26, 0.4), line: rgb(0.7, 0.92, 1.0), pattern: .arcs)),
        Product(title: "Citi Custom Cash", face: "CUSTOM CASH", issuer: "Citi", phrases: ["custom cash"],
                look: Look(top: rgb(0.3, 0.6, 0.72), bottom: rgb(0.1, 0.34, 0.5), line: .white, pattern: .rings)),
        Product(title: "Citi Strata Premier", face: "STRATA PREMIER", issuer: "Citi", phrases: ["strata premier", "citi premier"], fees: [95],
                look: Look(top: rgb(0.1, 0.2, 0.4), bottom: rgb(0.03, 0.08, 0.2), line: rgb(0.5, 0.7, 1.0), pattern: .rings)),
        Product(title: "Costco Anywhere Visa", face: "COSTCO ANYWHERE", issuer: "Citi", phrases: ["costco anywhere"],
                look: Look(top: rgb(0.62, 0.64, 0.68), bottom: rgb(0.34, 0.36, 0.4), line: .white, pattern: .weave)),
        Product(title: "Citi AAdvantage", face: "AADVANTAGE", issuer: "Citi", phrases: ["aadvantage"],
                look: Look(top: rgb(0.5, 0.55, 0.62), bottom: rgb(0.22, 0.26, 0.33), line: rgb(0.85, 0.25, 0.25), pattern: .bands)),
        // Others
        Product(title: "Coinbase One Card", face: "coinbase", issuer: "Coinbase", phrases: ["coinbase"],
                look: Look(top: rgb(0.11, 0.11, 0.12), bottom: rgb(0.02, 0.02, 0.03), line: rgb(0.78, 0.8, 0.84), pattern: .code)),
        Product(title: "Apple Card", face: "", issuer: "Apple Card", phrases: ["apple card"],
                look: Look(top: rgb(0.97, 0.97, 0.98), bottom: rgb(0.86, 0.87, 0.89), line: rgb(0.6, 0.6, 0.65), pattern: .plain, darkInk: true)),
        Product(title: "Discover it", face: "DISCOVER IT", issuer: "Discover", phrases: ["discover it"],
                look: Look(top: rgb(0.96, 0.55, 0.2), bottom: rgb(0.75, 0.3, 0.08), line: .white, pattern: .arcs)),
        Product(title: "Wells Fargo Active Cash", face: "ACTIVE CASH", issuer: "Wells Fargo", phrases: ["active cash"],
                look: Look(top: rgb(0.72, 0.14, 0.16), bottom: rgb(0.42, 0.05, 0.08), line: rgb(1.0, 0.82, 0.3), pattern: .bands)),
        Product(title: "Bank of America Customized Cash", face: "CUSTOMIZED CASH", issuer: "Bank of America", phrases: ["customized cash"],
                look: Look(top: rgb(0.72, 0.12, 0.2), bottom: rgb(0.4, 0.05, 0.1), line: .white, pattern: .bands)),
        Product(title: "U.S. Bank Altitude Reserve", face: "ALTITUDE RESERVE", issuer: "U.S. Bank", phrases: ["altitude reserve"], fees: [400],
                look: Look(top: rgb(0.14, 0.17, 0.24), bottom: rgb(0.04, 0.05, 0.09), line: rgb(0.6, 0.66, 0.8), pattern: .weave)),
    ]

    static func product(titled title: String?) -> Product? { title.flatMap { t in products.first { $0.title == t } } }

    /// Which card this is, from what its statements print, the yearly fees it has charged and the
    /// names of its credits. A name printed on the statement settles it; otherwise a fee that only
    /// one of the issuer's cards has charged does, when a sibling word agrees. Nil when it is not
    /// clear: a wrong name is worse than the issuer's alone.
    static func find(issuer: String, statementText: String, fees: [Double], lineWords: String) -> Product? {
        let text = statementText.lowercased(), lines = lineWords.lowercased()
        var best: (product: Product, score: Int, length: Int)?, tied = false
        for product in products where product.issuer == issuer {
            let named = product.phrases.filter { text.contains($0) }.map(\.count).max()
            var score = named != nil ? 3 : 0
            if !product.fees.isEmpty, fees.contains(where: { fee in product.fees.contains { abs($0 - fee) < 0.5 } }) { score += 2 }
            if product.hints.contains(where: { text.contains($0) || lines.contains($0) }) { score += 1 }
            guard score >= 3 else { continue }
            let length = named ?? 0
            if let held = best {
                if (score, length) == (held.score, held.length) { tied = true }
                if (score, length) > (held.score, held.length) { best = (product, score, length); tied = false }
            } else {
                best = (product, score, length)
            }
        }
        return tied ? nil : best?.product
    }

    /// A look for a card that is not in the catalogue: the issuer's colour if it has one, else a steady colour from the name.
    static func look(forUnknown name: String, issuer: String?) -> Look {
        switch issuer {
        case "Chase": return Look(top: rgb(0.14, 0.34, 0.62), bottom: rgb(0.05, 0.14, 0.36), line: .white, pattern: .arcs)
        case "American Express": return Look(top: rgb(0.3, 0.55, 0.8), bottom: rgb(0.1, 0.3, 0.58), line: .white, pattern: .frame)
        case "Citi": return Look(top: rgb(0.16, 0.42, 0.66), bottom: rgb(0.05, 0.2, 0.42), line: .white, pattern: .rings)
        case "Capital One": return Look(top: rgb(0.16, 0.26, 0.44), bottom: rgb(0.06, 0.1, 0.22), line: rgb(0.85, 0.3, 0.3), pattern: .bands)
        default:
            let seed = name.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
            let hue = Double(seed % 360) / 360
            return Look(top: Color(hue: hue, saturation: 0.55, brightness: 0.52), bottom: Color(hue: (hue + 0.06).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.26),
                        line: .white, pattern: .plain)
        }
    }
}

/// The pattern on a card's face, drawn in one colour at low strength.
struct CardPattern: View {
    let look: CardCatalog.Look

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height, ink = look.line
            switch look.pattern {
            case .plain:
                break
            case .waves:
                // Long lines sweeping up across the face, bunching toward the right like light on water.
                for i in 0..<9 {
                    let t = CGFloat(i) / 8
                    var path = Path()
                    path.move(to: CGPoint(x: -w * 0.05, y: h * (0.55 + t * 0.6)))
                    path.addCurve(to: CGPoint(x: w * 1.05, y: h * (-0.25 + t * 0.75)),
                                  control1: CGPoint(x: w * 0.35, y: h * (0.75 + t * 0.2)), control2: CGPoint(x: w * 0.6, y: h * (-0.2 + t * 0.9)))
                    context.stroke(path, with: .color(ink.opacity(0.1 + 0.16 * Double(1 - abs(t - 0.5) * 2))), lineWidth: 0.9 + t * 0.8)
                }
                var sweep = Path()
                sweep.move(to: CGPoint(x: w * 0.42, y: h * 1.05))
                sweep.addCurve(to: CGPoint(x: w * 1.05, y: h * 0.18), control1: CGPoint(x: w * 0.62, y: h * 0.7), control2: CGPoint(x: w * 0.8, y: h * 0.25))
                sweep.addLine(to: CGPoint(x: w * 1.05, y: h * 0.5))
                sweep.addCurve(to: CGPoint(x: w * 0.66, y: h * 1.05), control1: CGPoint(x: w * 0.9, y: h * 0.6), control2: CGPoint(x: w * 0.76, y: h * 0.85))
                sweep.closeSubpath()
                context.fill(sweep, with: .linearGradient(Gradient(colors: [ink.opacity(0.0), ink.opacity(0.22)]), startPoint: CGPoint(x: w * 0.4, y: h), endPoint: CGPoint(x: w, y: h * 0.2)))
            case .facets:
                // The cut faces of a gem: a net of triangles, each catching the light a little differently.
                let columns = 6, rows = 4
                func noise(_ a: Int, _ b: Int) -> CGFloat { let v = sin(CGFloat(a) * 12.9898 + CGFloat(b) * 78.233) * 43758.5453; return v - v.rounded(.down) }
                func point(_ c: Int, _ r: Int) -> CGPoint {
                    let edge = c == 0 || r == 0 || c == columns || r == rows
                    let dx = edge ? 0 : (noise(c, r) - 0.5) * 0.6, dy = edge ? 0 : (noise(r + 7, c + 3) - 0.5) * 0.6
                    return CGPoint(x: (CGFloat(c) + dx) / CGFloat(columns) * w, y: (CGFloat(r) + dy) / CGFloat(rows) * h)
                }
                for c in 0..<columns {
                    for r in 0..<rows {
                        let a = point(c, r), b = point(c + 1, r), d = point(c, r + 1), e = point(c + 1, r + 1)
                        let split = noise(c + 11, r + 5) > 0.5
                        let triangles = split ? [[a, b, e], [a, e, d]] : [[a, b, d], [b, e, d]]
                        for (n, triangle) in triangles.enumerated() {
                            var path = Path()
                            path.move(to: triangle[0]); path.addLine(to: triangle[1]); path.addLine(to: triangle[2]); path.closeSubpath()
                            // Brighter toward the lower right, where the light falls.
                            let lit = Double(noise(c * 3 + n, r * 5 + 1)) * (0.05 + 0.2 * Double(c + r) / Double(columns + rows))
                            context.fill(path, with: .color(ink.opacity(lit)))
                            context.stroke(path, with: .color(ink.opacity(0.13)), lineWidth: 0.5)
                        }
                    }
                }
            case .code:
                // Rows of small type covering the face, as if engraved: the first block of the first chain, in hexadecimal.
                let block = "0100000000000000000000000000000000000000000000000000000000000000000000003BA3EDFD7A7B12B27AC72C3E67768F617FC81BC3888A51323A9FB8AA4B1E5E4A29AB5F49FFFF001D1DAC2B7C0101000000010000000000000000000000000000000000000000000000000000000000000000FFFFFFFF4D04FFFF001D0104455468652054696D65732030332F4A616E2F32303039204368616E63656C6C6F72206F6E206272696E6B206F66207365636F6E64206261696C6F757420666F722062616E6B73"
                let letters = Array(block), size = max(4.5, w * 0.024), perRow = Int(w / (size * 0.62)) + 2
                var row = 0, y = size * 0.9
                while y < h + size {
                    let from = (row * perRow) % letters.count
                    let text = String((0..<perRow).map { letters[(from + $0) % letters.count] })
                    // Some rows are cut a little deeper than others.
                    let depth = 0.1 + 0.12 * Double((row * 7) % 5) / 4
                    context.draw(Text(text).font(.system(size: size, weight: .medium, design: .monospaced)).foregroundColor(ink.opacity(depth)),
                                 at: CGPoint(x: 0, y: y), anchor: .leading)
                    y += size * 1.28; row += 1
                }
                // A soft band of light across the metal.
                var band = Path()
                band.move(to: CGPoint(x: w * 0.5, y: 0)); band.addLine(to: CGPoint(x: w * 0.78, y: 0)); band.addLine(to: CGPoint(x: w * 0.42, y: h)); band.addLine(to: CGPoint(x: w * 0.14, y: h)); band.closeSubpath()
                context.fill(band, with: .color(.white.opacity(0.045)))
            case .frame:
                // Brushed metal: hairlines of uneven strength, edge to edge.
                var by: CGFloat = 0, n = 0
                while by < h {
                    let v = sin(CGFloat(n) * 91.7) * 43758.5453, strength = Double(v - v.rounded(.down))
                    context.fill(Path(CGRect(x: 0, y: by, width: w, height: 0.6)), with: .color((strength > 0.5 ? Color.white : ink).opacity(0.05 + strength * 0.07)))
                    by += 1.3; n += 1
                }
                // An engraved border: a rule, a row of beads, a second rule, like the edge of a banknote.
                let outer = CGRect(x: w * 0.04, y: w * 0.04, width: w - w * 0.08, height: h - w * 0.08)
                context.stroke(Path(roundedRect: outer, cornerRadius: w * 0.032), with: .color(ink.opacity(0.55)), lineWidth: 0.9)
                let beads = outer.insetBy(dx: w * 0.014, dy: w * 0.014), bead = w * 0.009
                var bx = beads.minX + bead
                while bx < beads.maxX - bead {
                    for byEdge in [beads.minY, beads.maxY] { context.fill(Path(ellipseIn: CGRect(x: bx - bead / 2, y: byEdge - bead / 2, width: bead, height: bead)), with: .color(ink.opacity(0.35))) }
                    bx += bead * 1.9
                }
                var bEdge = beads.minY + bead * 1.9
                while bEdge < beads.maxY - bead {
                    for bxEdge in [beads.minX, beads.maxX] { context.fill(Path(ellipseIn: CGRect(x: bxEdge - bead / 2, y: bEdge - bead / 2, width: bead, height: bead)), with: .color(ink.opacity(0.35))) }
                    bEdge += bead * 1.9
                }
                let inner = outer.insetBy(dx: w * 0.028, dy: w * 0.028)
                context.stroke(Path(roundedRect: inner, cornerRadius: w * 0.02), with: .color(ink.opacity(0.3)), lineWidth: 0.6)
                // Fans in the corners.
                for corner in [CGPoint(x: inner.minX, y: inner.minY), CGPoint(x: inner.maxX, y: inner.minY), CGPoint(x: inner.minX, y: inner.maxY), CGPoint(x: inner.maxX, y: inner.maxY)] {
                    for i in 1...4 {
                        let r = w * 0.022 * CGFloat(i)
                        var fan = context
                        fan.clip(to: Path(inner))
                        fan.stroke(Path(ellipseIn: CGRect(x: corner.x - r, y: corner.y - r, width: r * 2, height: r * 2)), with: .color(ink.opacity(0.22)), lineWidth: 0.5)
                    }
                }
                // The medallion: a rosette of fine loops, such as a lathe engraves, around a plain boss.
                let centre = CGPoint(x: w * 0.5, y: h * 0.52), reach = h * 0.27
                for i in 0..<48 {
                    let angle = CGFloat(i) / 48 * 2 * .pi
                    var petal = context
                    petal.translateBy(x: centre.x, y: centre.y)
                    petal.rotate(by: .radians(angle))
                    petal.stroke(Path(ellipseIn: CGRect(x: 0, y: -reach * 0.2, width: reach, height: reach * 0.4)), with: .color(ink.opacity(0.2)), lineWidth: 0.45)
                }
                for (scale, strength) in [(1.04, 0.45), (0.5, 0.35), (0.44, 0.2)] {
                    let r = reach * scale
                    context.stroke(Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)), with: .color(ink.opacity(strength)), lineWidth: 0.7)
                }
                let boss = reach * 0.42
                context.fill(Path(ellipseIn: CGRect(x: centre.x - boss, y: centre.y - boss, width: boss * 2, height: boss * 2)),
                             with: .linearGradient(Gradient(colors: [.white.opacity(0.55), look.bottom.opacity(0.5)]), startPoint: CGPoint(x: centre.x - boss, y: centre.y - boss), endPoint: CGPoint(x: centre.x + boss, y: centre.y + boss)))
            case .arcs:
                for i in 1...6 {
                    let r = w * 0.16 * CGFloat(i)
                    context.stroke(Path(ellipseIn: CGRect(x: w * 1.02 - r, y: h * 1.05 - r, width: r * 2, height: r * 2)), with: .color(ink.opacity(0.2 - Double(i) * 0.022)), lineWidth: w * 0.035)
                }
            case .bands:
                for i in 0..<4 {
                    var path = Path()
                    let x = w * (0.42 + CGFloat(i) * 0.17)
                    path.move(to: CGPoint(x: x, y: -2)); path.addLine(to: CGPoint(x: x + w * 0.09, y: -2))
                    path.addLine(to: CGPoint(x: x - w * 0.22, y: h + 2)); path.addLine(to: CGPoint(x: x - w * 0.31, y: h + 2))
                    path.closeSubpath()
                    context.fill(path, with: .color(ink.opacity(0.07 + Double(i) * 0.035)))
                }
            case .rings:
                for i in 1...7 {
                    let r = w * 0.075 * CGFloat(i)
                    context.stroke(Path(ellipseIn: CGRect(x: w * 0.74 - r, y: h * 0.48 - r, width: r * 2, height: r * 2)), with: .color(ink.opacity(0.24 - Double(i) * 0.025)), lineWidth: 1)
                }
            case .weave:
                var x = -h
                while x < w {
                    var a = Path(); a.move(to: CGPoint(x: x, y: 0)); a.addLine(to: CGPoint(x: x + h, y: h))
                    var b = Path(); b.move(to: CGPoint(x: x + h, y: 0)); b.addLine(to: CGPoint(x: x, y: h))
                    context.stroke(a, with: .color(ink.opacity(0.07)), lineWidth: 0.6)
                    context.stroke(b, with: .color(ink.opacity(0.07)), lineWidth: 0.6)
                    x += 9
                }
            }
        }
        .allowsHitTesting(false)
    }
}

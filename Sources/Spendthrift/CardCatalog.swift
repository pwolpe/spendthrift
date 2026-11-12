import SwiftUI

/// The well-known cards, so a card can be called what its owner calls it and drawn so they know it
/// at a glance. This is general knowledge about card products (their names, the words their
/// statements print, the yearly fees they have charged, their colours), not anything about one
/// person. Nothing here is about benefits: the Cards pages take those from the statements alone.
///
/// The drawings are the app's own: a colour and a pattern in the spirit of the card, with no
/// issuer's logo or artwork copied.
enum CardCatalog {
    enum Pattern { case plain, waves, frame, arcs, bands, rings, weave }

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
                look: Look(top: rgb(0.07, 0.15, 0.33), bottom: rgb(0.02, 0.05, 0.14), line: rgb(0.36, 0.56, 0.93), pattern: .waves)),
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
        Product(title: "Coinbase Card", face: "COINBASE", issuer: "Coinbase", phrases: ["coinbase"],
                look: Look(top: rgb(0.1, 0.36, 0.95), bottom: rgb(0.03, 0.18, 0.62), line: .white, pattern: .rings)),
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
            case .frame:
                // An engraved border, fine ruled lines inside it, and an oval at the centre, like a banknote.
                for (inset, strength) in [(0.045, 0.5), (0.065, 0.25)] {
                    let rect = CGRect(x: w * inset, y: w * inset, width: w - 2 * w * inset, height: h - 2 * w * inset)
                    context.stroke(Path(roundedRect: rect, cornerRadius: w * 0.03), with: .color(ink.opacity(strength)), lineWidth: 0.8)
                }
                var y = h * 0.14
                while y < h * 0.88 {
                    var path = Path()
                    path.move(to: CGPoint(x: w * 0.085, y: y))
                    var x = w * 0.085
                    while x < w * 0.915 { x += 3; path.addLine(to: CGPoint(x: x, y: y + sin(x / w * 28) * 1.2)) }
                    context.stroke(path, with: .color(ink.opacity(0.09)), lineWidth: 0.5)
                    y += 4.5
                }
                let oval = CGRect(x: w * 0.37, y: h * 0.26, width: w * 0.26, height: h * 0.48)
                context.fill(Path(ellipseIn: oval), with: .color(look.top.opacity(0.55)))
                context.stroke(Path(ellipseIn: oval), with: .color(ink.opacity(0.4)), lineWidth: 0.9)
                context.stroke(Path(ellipseIn: oval.insetBy(dx: w * 0.012, dy: w * 0.012)), with: .color(ink.opacity(0.2)), lineWidth: 0.6)
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

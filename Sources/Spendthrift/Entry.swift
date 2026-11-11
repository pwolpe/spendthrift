import PDFKit
import SwiftUI
import AppKit

/// Normal launches open the app. The build script also runs
/// `open -W "Spendthrift.app" --args --make-icon <out.png> --cartoon <cartoon.png>`
/// to bake cartoon Tony into the icon. Image Playground only works in a foreground app,
/// so this mode shows a small window while it works.
@main
enum Entry {
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered logs for debugging
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--compose"), i + 4 < args.count {
            // Debug aid: --compose <caricature> <backdrop|-> <prop|-> <out.png>
            let img = { (p: String) in p == "-" ? nil : NSImage(contentsOfFile: p) }
            if let car = img(args[i + 1]),
               let out = Compositor.compose(caricature: car, backdrop: img(args[i + 2]), prop: img(args[i + 3]),
                                            propSymbol: "cup.and.saucer.fill", tint: .systemOrange) {
                print("hand:", Compositor.handPoint(car.cgImage(forProposedRect: nil, context: nil, hints: nil)!))
                try? IconRenderer.png(out)?.write(to: URL(fileURLWithPath: args[i + 4]))
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--looks-like-statement") {
            for path in args[(i + 1)...] {
                print(PDFStatement.looksLikeStatement(URL(fileURLWithPath: path)) ? "YES" : "no ", (path as NSString).lastPathComponent)
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--blanked") {
            // Test aid: print exactly what would be sent to the cloud for a statement, without sending it.
            for path in args[(i + 1)...] {
                guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { continue }
                let text = (0..<doc.pageCount).compactMap { doc.page(at: $0) }.map(PDFStatement.positionalText).joined(separator: "\n")
                print(Redactor.blank(text))
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--read-test"), i + 3 < args.count {
            // Test aid: --read-test <model> <outdir> files… Has one model read each statement the way the
            // app would ask it to, and writes what it read, so models can be compared on the same pages.
            let model = args[i + 1], out = URL(fileURLWithPath: args[i + 2], isDirectory: true)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let files = Array(args[(i + 3)...])
            Task {
                await CloudAI.$modelOverride.withValue(model) {
                    await withTaskGroup(of: Void.self) { group in
                        var next = 0
                        func start() {
                            guard next < files.count else { return }
                            let path = files[next]; next += 1
                            group.addTask {
                                let url = URL(fileURLWithPath: path)
                                guard let doc = PDFDocument(url: url) else { return }
                                let pages = (0..<min(doc.pageCount, 200)).compactMap { doc.page(at: $0) }
                                let stored = pages.compactMap(\.string).joined(separator: "\n")
                                let text = await MainActor.run { pages.map(PDFStatement.positionalText).joined(separator: "\n") }
                                let closing = PDFStatement.detectClosingDate(stored) ?? .now
                                let started = Date.now
                                let reading = await CloudStatementReader.read(text: text, closing: closing)
                                let rows = (reading?.rows ?? []).map { [$0.date, $0.description, String(format: "%.2f", $0.amount)] }
                                let result: [String: Any] = ["file": url.lastPathComponent, "read": reading != nil, "verified": reading?.verified ?? false,
                                                             "seconds": Date.now.timeIntervalSince(started), "rows": rows]
                                if let data = try? JSONSerialization.data(withJSONObject: result) {
                                    try? data.write(to: out.appendingPathComponent(url.lastPathComponent + ".json"))
                                }
                                print("READTEST \(model) \(url.lastPathComponent) rows \(rows.count) verified \(reading?.verified ?? false) \(String(format: "%.0fs", Date.now.timeIntervalSince(started)))")
                            }
                        }
                        for _ in 0..<6 { start() }
                        for await _ in group { start() }
                    }
                }
                try? await Task.sleep(for: .seconds(2))   // let the last costs be noted
                exit(0)
            }
            dispatchMain()
        }
        if let i = args.firstIndex(of: "--check") {
            // Test aid: one line per file saying how it was read.
            Task { @MainActor in
                for path in args[(i + 1)...] {
                    let url = URL(fileURLWithPath: path)
                    let started = Date.now
                    var line: String
                    do {
                        guard StatementReader.extensions.contains(url.pathExtension.lowercased()) else {
                            print("CHECK \(url.lastPathComponent) | unsupported | \(StatementReader.adviceForUnsupported(url))"); continue
                        }
                        switch try await StatementReader.read(url, data: Data(contentsOf: url)) {
                        case .needsMapping(_, _, let name): line = "needs-mapping | \(name)"
                        case .ready(let s):
                            let out = s.rows.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }
                            let moneyIn = s.rows.filter { $0.amount < 0 }.reduce(0) { $0 - $1.amount }
                            line = "ok | rows=\(s.rows.count) out=\(String(format: "%.2f", out)) in=\(String(format: "%.2f", moneyIn)) | \(s.suggestedName) | \(s.check)"
                        }
                    } catch { line = "error | \(error.localizedDescription)" }
                    print("CHECK \(url.lastPathComponent) | \(line) | \(String(format: "%.2fs", Date.now.timeIntervalSince(started)))")
                }
                exit(0)
            }
            dispatchMain()
        }
        if let i = args.firstIndex(of: "--inspect") {
            // Debug aid: show how statement files would be read and sorted (without AI).
            Task { @MainActor in
                for path in args[(i + 1)...] {
                    let url = URL(fileURLWithPath: path)
                    do {
                        if url.pathExtension.lowercased() == "pdf", let doc = PDFDocument(url: url) {
                            let text = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
                            print("   closing date: \(PDFStatement.detectClosingDate(text).map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "none")")
                        }
                        switch try await StatementReader.read(url, data: Data(contentsOf: url)) {
                        case .needsMapping(_, let signature, let name):
                            print("== \(url.lastPathComponent)\n   NEEDS MAPPING  signature: \(signature)  name: \(name)")
                        case .ready(let s):
                            print("== \(url.lastPathComponent)\n   signature: \(s.signature)\n   name: \(s.suggestedName)\n   rows: \(s.rows.count)  check: \(s.check)")
                            for row in (s.rows.count <= 60 ? s.rows : Array(s.rows.prefix(4) + s.rows.suffix(2))) {
                                let info = MerchantResolver.instant(description: row.description, amount: row.amount, bankCategory: row.bankCategory)
                                let line = "   \(row.date)  \(row.description.padding(toLength: 34, withPad: " ", startingAt: 0)) \(String(format: "%9.2f", row.amount))"
                                print(line + "  → \(info.name) | \(info.category?.rawValue ?? "ask AI") | \(info.source.rawValue)")
                            }
                        }
                    } catch { print("== \(url.lastPathComponent): ERROR \(error.localizedDescription)") }
                }
                exit(0)
            }
            dispatchMain()
        }
        guard let i = args.firstIndex(of: "--make-icon"), i + 1 < args.count else {
            SpendthriftApp.main()
            return
        }
        let iconOut = URL(fileURLWithPath: args[i + 1])
        let cartoonOut = args.firstIndex(of: "--cartoon").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 110),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Spendthrift"
        window.contentView = NSHostingView(rootView:
            HStack(spacing: 14) {
                ProgressView()
                Text("Drawing the app icon…").font(.headline)
            }.frame(width: 360, height: 110))
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate()

        Task { @MainActor in
            var cartoon = cartoonOut.flatMap { NSImage(contentsOf: $0) }
            if cartoon == nil, let photo = DailyPicture.shared.headshot {
                cartoon = await CartoonMaker.cartoon(from: photo)
                if let cartoon, let cartoonOut { try? IconRenderer.png(cartoon)?.write(to: cartoonOut) }
            }
            let face = cartoon ?? DailyPicture.shared.headshot
            let data = IconRenderer.png(IconRenderer.icon(face: face, isCartoon: cartoon != nil))
            try? data?.write(to: iconOut)
            exit(data == nil ? 1 : 0)
        }
        app.run()
    }
}

import Foundation
import PDFKit
import AppKit
import Observation

// MARK: - Drawing Tony

/// The banner picture, drawn by a cloud image model from Tony's real photo: a cartoon of him living
/// out a daydream about a purchase he really made. The photo goes along every time so it stays him.
enum CloudImage {
    static let defaultModel = "google/gemini-nano-banana-2.1"
    static var model: String {
        get { UserDefaults.standard.string(forKey: "cloudImageModel") ?? defaultModel }
        set { UserDefaults.standard.set(newValue, forKey: "cloudImageModel") }
    }

    /// The best image model on offer today. Image models improve every few months, so rather than
    /// name one here for good, the app reads what's available and has the writing model choose.
    static func bestModel() async -> String {
        guard let url = URL(string: "https://openrouter.ai/api/v1/models"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let all = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]] else { return model }
        let candidates = all.filter { entry in
            let shape = entry["architecture"] as? [String: Any]
            let id = entry["id"] as? String ?? ""
            return (shape?["output_modalities"] as? [String])?.contains("image") == true
                && (shape?["input_modalities"] as? [String])?.contains("image") == true
                && !id.hasPrefix("openrouter/")
        }
        let ids = candidates.compactMap { $0["id"] as? String }
        guard !ids.isEmpty else { return model }
        let lines = candidates.map { entry -> String in
            let released = Date(timeIntervalSince1970: (entry["created"] as? Double) ?? 0).formatted(.iso8601.year().month().day())
            let about = String(((entry["description"] as? String) ?? "").prefix(220)).replacingOccurrences(of: "\n", with: " ")
            return "\(entry["id"] as? String ?? "") | \(entry["name"] as? String ?? "") | released \(released) | \(about)"
        }
        let system = """
        Choose the one image model that will draw the best picture for this job: given a photo of a real man, \
        draw a rich, funny, cartoon illustration of him in an imagined scene, keeping his face unmistakably his. \
        Prefer the most capable, most recently released model with a strong record of keeping a person's likeness \
        from a reference photo. Avoid "lite", "mini" and "preview" versions, and prefer a model that draws in \
        around ten seconds over a slower one of similar quality. Reply with JSON only: {"model": "<id exactly as listed>"}
        """
        let reply = await Timeout.run(30) {
            try? await CloudAI.complete(job: "Daily picture: planning", system: system, user: lines.joined(separator: "\n"), json: true, maxTokens: 2_000, timeout: 25)
        }
        if let reply, let choice = CloudAI.object(from: reply)?["model"] as? String, ids.contains(choice) {
            model = choice
            return choice
        }
        return ids.contains(model) ? model : defaultModel
    }

    struct Scene: Sendable {
        let scene: String
        let caption: String
        /// What that business sells, in two or three words, for the receipt ("Coffee & donuts").
        let what: String
    }

    /// The words printed on the receipt someone in the picture holds.
    struct Receipt: Sendable {
        let merchant: String
        let what: String
        let total: String
        /// Short enough to print large: "FARMER AND THE FISH".
        var heading: String {
            var words: [String] = []
            for word in merchant.uppercased().split(separator: " ").map(String.init) {
                if (words + [word]).joined(separator: " ").count > 26, !words.isEmpty { break }
                words.append(word)
            }
            return String(words.joined(separator: " ").prefix(26))
        }
    }

    /// One sentence saying what is going on in the picture, and the dry line printed under it.
    static func scene(merchant: String, category: String, amount: Double, cast: [String] = ["Tony"], trip: String? = nil, tripPlace: String? = nil) async -> Scene? {
        let system = """
        You design the picture at the top of Spendthrift, a playful personal budgeting app starring two friends, \
        Tony and Paul. Each picture is a cartoon of one or both of them in a Walter Mitty daydream: an ordinary purchase he really made, \
        blown up into a wildly heroic, absurd, joyful fantasy. Seeing it should make him laugh out loud, because \
        it is so specifically about where he really just spent money.

        Given the purchase, reply with JSON only: {"scene": "...", "receipt": "...", "what": "...", "caption": "..."}

        scene: one or two sentences, starting with "he is", describing the daydream: what he is (or they are), what he is \
        doing, what he wears and where. Tie it concretely to this exact business: what it sells, its colors, its \
        setting, what people do there. Then exaggerate it into an adventure. Examples: a coffee and donut shop -> \
        "he is a triumphant explorer in a pith helmet, planting a flag on the summit of a mountain of glazed \
        donuts, a river of iced coffee running through an orange and pink valley below"; a rideshare -> "he is a \
        chariot racer in a Roman arena, the chariot a small pink-trimmed city car pulled by four scooters, the \
        crowd going wild"; an electric utility -> "he is a mad scientist in a castle laboratory, throwing a giant \
        switch as lightning lights a single enormous light bulb"; a parking garage -> "he is a stunt driver \
        leaping a convertible between the rooftops of two parking garages, valets holding up scorecards". \
        Any costume must leave his whole face clearly visible. Funny side characters and details are welcome. \
        Do not ask for any words, lettering or logos in the picture other than the receipt below.

        receipt: one sentence. In every picture one of them is holding the receipt for this purchase, and it is \
        part of the joke. Say who holds it and how, so that it belongs in this scene and feels natural there: held \
        aloft like a trophy, read like a treasure map, waved at a dragon, presented to a judge, clutched in triumph \
        at the finish line. It is always an ordinary long white paper till receipt, held flat and facing us, big \
        and close enough to read; never rolled up, folded, burning or turned away. Do not write what it says.

        what: what this business sells, in one to three plain words, as a receipt would list it ("Coffee & donuts", \
        "Groceries", "Car ride", "Electricity", "Dinner for two"). Do not invent specific items or brands.

        caption: one dry, fond line to print under the picture, at most 12 words, in the voice of a deadpan \
        bookkeeper who is quietly amused by this purchase and this daydream. Wry, specific, never scolding. \
        No awards-show language, no "Nominated", no exclamation marks. Do not mention the amount.
        """
        // A different flavor of daydream each time, so the pictures don't settle into one joke.
        let flavor = ["a blockbuster action movie", "a space adventure", "a medieval legend", "a spy thriller", "a nature documentary",
                      "an Olympic final", "a superhero comic", "a jungle expedition", "a rock concert", "a fairy tale", "a heist movie",
                      "a western", "a monster movie", "an old Hollywood musical", "a polar expedition", "a magic show",
                      "a samurai epic", "a circus", "a pirate adventure", "a deep sea voyage"].randomElement()!
        let who = cast.count > 1
            ? " This picture stars two friends, \(cast.joined(separator: " and ")), together: start the scene with \"they are\" and give each of them something to do. Say by name which of them holds the receipt. The caption may name them both."
            : " This picture stars \(cast[0]) alone: \"he\" is \(cast[0]), the only one of the two friends in the picture, and he is the one holding the receipt. Do not mention or include \(cast[0] == "Tony" ? "Paul" : "Tony"), and do not use either name in the scene or the receipt sentence: write \"he\"."
        // A purchase from a trip is set where the trip was: that is what makes someone ask how it knew.
        let place = [trip, tripPlace].compactMap { $0 }.joined(separator: ", ")
        let away = place.isEmpty ? "" : " This was bought on a trip: \(place). Set the daydream unmistakably there: its landscape, landmarks, weather and local color, with this business as part of the scene."
        let user = "Purchase: \(merchant) (\(category)), \(Money.format(amount)). This time, make the daydream \(flavor).\(away)\(who) Hats, helmets and masks stay off his head so the whole face shows."
        let reply = await Timeout.run(40) {
            try? await CloudAI.complete(job: "Daily picture: planning", system: system, user: user, json: true, maxTokens: 3_000, temperature: 1.0, timeout: 35)
        }
        guard let reply, let o = CloudAI.object(from: reply), var scene = (o["scene"] as? String), !scene.isEmpty else { return nil }
        if let holding = o["receipt"] as? String, !holding.isEmpty { scene += " " + holding }
        let what = String(((o["what"] as? String) ?? category).prefix(26))
        var caption = ((o["caption"] as? String) ?? "").replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
        if caption.isEmpty || caption.count > 120 || caption.hasPrefix("Nominated") { caption = "Filed under: worth it. \(merchant)." }
        return Scene(scene: scene, caption: caption, what: what.isEmpty ? category : what)
    }

    /// Draws the scene as a wide cartoon, with Tony's photo as the model for his face. Nil if it couldn't be drawn.
    /// Every picture is drawn in a different manner, so opening the app is a small surprise each time.
    /// Only manners that can carry a real face: each was tried with the photos, and flatter ones
    /// (pixel art, paper cut, woodblock) lost the likeness.
    static let styles: [(id: String, look: String)] = [
        ("3d", "a modern 3D animated feature film: soft rounded shapes, rich lighting, expressive faces"),
        ("strip", "a classic mid-century newspaper comic strip: a slightly wobbly hand-inked black line, flat muted colors, very little shading, gentle deadpan humor"),
        ("clay", "stop-motion claymation: everything sculpted from modelling clay with visible thumbprints, miniature handmade sets, warm studio lighting"),
        ("anime", "a hand-painted Japanese animated film: lush painted backgrounds, soft clean line work, gentle colors, a sense of wonder"),
        ("popart", "a 1960s pop-art comic book panel: thick black ink outlines, halftone dots, flat primary colors, dramatic action lines"),
        ("poster", "a vintage 1930s travel poster: flat screen-printed color blocks, strong geometric composition, a limited warm palette, subtle paper grain"),
        ("watercolor", "a loose ink-and-watercolor magazine cartoon: quick confident pen lines, soft washes of color, plenty of white paper, dry wit"),
        ("saturday", "a 1960s Saturday-morning television cartoon: flat cel colors, thick clean outlines, stylized angular backgrounds, big goofy energy"),
    ]

    /// Draws the scene with the real photos as the reference for each face. Likeness comes first:
    /// the head is a faithful, detailed caricature portrait, and only the rest takes on the style.
    static func draw(scene: String, cast: [(name: String, photo: Data)], model: String, style: String, receipt: Receipt) async -> Data? {
        guard let key = CloudKey.load(), !cast.isEmpty else { return nil }
        let intro = cast.count == 1
            ? "The attached photo is \(cast[0].name), a real person. Make a picture starring him."
            : "The first attached photo is \(cast[0].name) and the second is \(cast[1].name), two real people who are friends. Make a picture starring both of them together, each clearly himself."
        let star = cast.count == 1 ? "\(cast[0].name) is the star" : "\(cast[0].name) and \(cast[1].name) are the stars, side by side"
        let prompt = """
        \(intro)
        Likeness comes first. Treat each photo as the reference for that man's head and reproduce it faithfully: \
        the exact face shape and proportions, hairline and hair, eyebrows, eyes, nose, mouth and smile, any beard or \
        stubble exactly as it is, and glasses if and only if he wears them in his photo, in the same frame shape. Do \
        not simplify, beautify, slim, age or generalize the face into a generic cartoon character. A colleague \
        glancing at the picture must know instantly who it is. Render the head as a detailed caricature portrait: \
        slightly larger than life, the face fully recognizable, three-quarter or front view, well lit, nothing covering it.
        Everything else (the body, costume, props, other characters and the setting) is drawn in this style: \(style). \
        The head is finished in the same medium so it belongs in the picture, but it keeps the full detail and true \
        likeness of the photo.
        The scene, a Walter Mitty daydream: \(scene)
        The receipt: \(cast.count == 1 ? "he holds" : "one of them holds") a paper till receipt for this purchase, as the scene \
        describes. It is a real prop in the picture, lit and shaded like everything else, in the hand of a person who \
        is doing something, not pasted on top. It is large (about a third of the picture's height), flat, facing \
        the viewer and unobstructed, with crisp black printed type on white paper. It reads exactly this, on three \
        lines, spelled exactly, and nothing else:
        \(receipt.heading)
        \(receipt.what)
        TOTAL \(receipt.total)
        The TOTAL line is the largest and boldest. Every character must be sharp and correct: check the digits.
        Very wide cinematic landscape picture (21:9). \(star): in the foreground, shown from about the waist up or \
        closer so the face is large, full of joy and swagger. Keep the bottom edge of the picture free of anything \
        important. Playful, full of funny details, the kind of picture that makes someone grin. Apart from the \
        receipt, no words, letters, numbers, logos, captions or watermarks anywhere.
        """
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        for member in cast {
            content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + member.photo.base64EncodedString()]])
        }
        let body: [String: Any] = [
            "model": model,
            "modalities": ["image", "text"],
            "image_config": ["aspect_ratio": "21:9"],
            "messages": [["role": "user", "content": content]],
            "usage": ["include": true],
        ]
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!, timeoutInterval: 150)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Spendthrift", forHTTPHeaderField: "X-Title")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              CloudSpend.note(job: "Daily picture: drawing", model: model, usage: object["usage"] as? [String: Any]) == (),
              let message = (object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
              let images = message["images"] as? [[String: Any]],
              let url = (images.first?["image_url"] as? [String: Any])?["url"] as? String,
              let comma = url.firstIndex(of: ","),
              let picture = Data(base64Encoded: String(url[url.index(after: comma)...])) else { return nil }
        return picture
    }
}

extension CloudImage {
    /// Has the picture's receipt come out readable and right? A second model looks at it and reads it back.
    /// Returns how much is right, 0 to 4 (held, easy to read, the total, the name); 4 is a pass.
    /// Nil when nobody could say (no connection); then the picture is kept.
    static func receiptReads(_ picture: Data, receipt: Receipt) async -> Int? {
        guard let key = CloudKey.load() else { return nil }
        let question = """
        In this picture someone should be holding a paper receipt. Read what is printed on it. Reply with JSON only: \
        {"held": true or false, "merchant": "<the name printed at the top, as you read it>", "total": "<the total printed, as you read it>", \
        "easy": true or false}. "held" is whether a person is clearly holding it. "easy" is whether an ordinary viewer \
        could read the name and the total at a glance, without zooming. If there is no receipt, use empty strings and false.
        """
        let body: [String: Any] = [
            "model": CloudAI.model,
            "max_tokens": 1_500,
            "usage": ["include": true],
            "messages": [["role": "user", "content": [
                ["type": "text", "text": question],
                ["type": "image_url", "image_url": ["url": "data:image/\(picture.first == 0xFF ? "jpeg" : "png");base64," + picture.base64EncodedString()]],
            ]]],
        ]
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Spendthrift", forHTTPHeaderField: "X-Title")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              CloudSpend.note(job: "Daily picture: checking the receipt", model: (body["model"] as? String) ?? "", usage: object["usage"] as? [String: Any]) == (),
              let message = (object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
              let text = message["content"] as? String, let o = CloudAI.object(from: text) else { return nil }
        let digits = { (s: String) in s.filter { $0.isNumber } }
        let letters = { (s: String) in String(s.uppercased().filter { $0.isLetter }) }
        let total = digits((o["total"] as? String) ?? ""), name = letters((o["merchant"] as? String) ?? "")
        let wanted = letters(receipt.heading)
        // The reader often runs the first two lines together ("HUMM Dining"), so the name need only lead.
        let nameRight = !wanted.isEmpty && (name.hasPrefix(wanted) || (name.count >= 4 && wanted.hasPrefix(name) && name.count * 10 >= wanted.count * 7))
        if ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil { print("DEBUG RECEIPT read: \(o)") }
        // The total counts double: a wrong number is the one thing the picture must never show.
        let totalRight = total == digits(receipt.total)
        return [(o["held"] as? Bool ?? false), (o["easy"] as? Bool ?? false), nameRight].filter { $0 }.count + (totalRight ? 1 : -3)
    }
}

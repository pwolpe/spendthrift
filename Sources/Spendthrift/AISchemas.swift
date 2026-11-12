import FoundationModels

/// Structured-output schemas built at runtime (no macros, so this builds with the
/// Command Line Tools as well as Xcode). The model is forced to answer in this shape.
enum AISchemas {
    static func string(_ name: String, _ description: String) -> DynamicGenerationSchema.Property {
        .init(name: name, description: description, schema: DynamicGenerationSchema(type: String.self))
    }

    static func choice(_ name: String, _ description: String, _ options: [String]) -> DynamicGenerationSchema.Property {
        .init(name: name, description: description, schema: DynamicGenerationSchema(name: name.capitalized + "Choice", anyOf: options))
    }

    /// Exactly `count` guesses. Without a fixed count the small model sometimes keeps inventing
    /// extra entries until it runs out of tokens, and the whole answer is lost.
    /// - purchasesOnly: no "Payments & Transfers" or "Income" to fall back on.
    static func merchantGuesses(count: Int, purchasesOnly: Bool) -> GenerationSchema? {
        let categories = purchasesOnly ? Category.spendingCases : Category.pickable
        let guess = DynamicGenerationSchema(name: "Guess", properties: [
            .init(name: "number", description: "The number of the transaction", schema: DynamicGenerationSchema(type: Int.self)),
            string("name", "The business name as written in the transaction, tidied up, like Whole Foods or Blue Door Cafe"),
            choice("category", "Budget category", categories.map(\.rawValue)),
        ])
        let root = DynamicGenerationSchema(name: "Guesses", properties: [
            .init(name: "guesses", description: "Exactly one guess for each numbered transaction",
                  schema: DynamicGenerationSchema(arrayOf: guess, minimumElements: count, maximumElements: count)),
        ])
        return try? GenerationSchema(root: root, dependencies: [])
    }

    /// Built fresh each time so Tony's own categories are included.
    static var spendingQuery: GenerationSchema? {
        let root = DynamicGenerationSchema(name: "Query", properties: [
            choice("metric", "What to compute", SpendingQuery.Metric.allCases.map(\.rawValue)),
            choice("category", "Category asked about, or any", Category.pickable.map(\.rawValue) + ["any"]),
            string("place", "Store or merchant named in the question, or any"),
        ])
        return try? GenerationSchema(root: root, dependencies: [])
    }

}

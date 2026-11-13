import Foundation

/// Every model the app uses, named once. When better ones come out, change the names here and
/// nothing else: no other file spells out a model (scripts/test.sh checks).
///
/// Before changing one, measure: `scripts/bench-models.sh` runs each of these beside the newest models
/// that could replace it, on cases with known answers, and says which to keep (ModelBench.swift).
/// It tests decision models at the thresholds that act on their answers (Tidy.swift, the 0.9 in
/// first-pass sorting), so a model it recommends can be named here with those left as they are.
enum Models {
    /// Judges, never writes: "the same business?", need or choice, which category. (Cloud/Decisions.swift)
    static let decision = "google/gemini-decision-1"

    /// Writes and reasons: sorting what the decision model is unsure of, Ask, summaries, captions.
    static let writing = "anthropic/claude-sonnet-5.5"

    /// A second opinion when reading a statement, from a different maker than `writing`.
    static let secondReader = "openai/gpt-6-luna"

    /// Draws the pictures.
    static let image = "google/gemini-nano-banana-2.1"
}

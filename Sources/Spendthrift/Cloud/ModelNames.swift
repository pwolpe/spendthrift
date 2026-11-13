import Foundation

/// Every model the app uses, named once. When better ones come out, change the names here and
/// nothing else: no other file spells out a model (scripts/test.sh checks).
///
/// Before switching a decision model, measure it: `SPENDTHRIFT_DECISION_BENCH` in DebugHooks compares
/// candidates on real payees, and the thresholds that act on its answers (Tidy.swift, the 0.9 in
/// first-pass sorting) were chosen from that measurement.
enum Models {
    /// Judges, never writes: "the same business?", need or choice, which category. (Cloud/Decisions.swift)
    static let decision = "google/gemini-decision-1"

    /// Writes and reasons: sorting what the decision model is unsure of, Ask, summaries, captions.
    static let writing = "anthropic/claude-sonnet-5.5"

    /// A second opinion when reading a statement, from a different maker than `writing`.
    static let secondReader = "google/gemini-3.7-flash"

    /// Draws the pictures.
    static let image = "google/gemini-nano-banana-2.1"
}

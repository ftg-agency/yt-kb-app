import Foundation

struct Segment: Equatable {
    let start: Double
    let end: Double
    let text: String
}

struct Transcript: Equatable {
    let segments: [Segment]
    let language: String
    let source: String  // "auto-subs" | "manual-subs"
    let isFallback: Bool
}

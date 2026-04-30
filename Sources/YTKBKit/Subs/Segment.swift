import Foundation

package struct Segment: Equatable {
    package let start: Double
    package let end: Double
    package let text: String

    package init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

package struct Transcript: Equatable {
    package let segments: [Segment]
    package let language: String
    package let source: String  // "auto-subs" | "manual-subs"
    package let isFallback: Bool

    package init(segments: [Segment], language: String, source: String, isFallback: Bool) {
        self.segments = segments
        self.language = language
        self.source = source
        self.isFallback = isFallback
    }
}

import Foundation

/// Parser for YouTube's `srv3` subtitle format (XML).
/// Schema: `<timedtext><body><p t="ms" d="ms"><s>text</s>...</p>...</body></timedtext>`.
/// Text can be in element body or in nested `<s>` spans.
package enum SRV3Parser {
    package static func parse(at url: URL) -> [Segment] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let delegate = SRV3Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            Logger.shared.warn("SRV3 parse failed: \(parser.parserError?.localizedDescription ?? "unknown")")
            return []
        }
        return VTTParser.dedupe(delegate.segments)
    }
}

private final class SRV3Delegate: NSObject, XMLParserDelegate {
    package var segments: [Segment] = []
    private var inP = false
    private var pStart: Double = 0
    private var pEnd: Double = 0
    private var textBuffer: String = ""

    package func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "p" {
            inP = true
            textBuffer = ""
            let start = Double(attributeDict["t"] ?? "0") ?? 0
            let dur = Double(attributeDict["d"] ?? "0") ?? 0
            pStart = start / 1000.0
            pEnd = (start + dur) / 1000.0
        }
        // <s> spans inside <p> contribute their text (handled in foundCharacters)
    }

    package func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inP {
            textBuffer.append(string)
        }
    }

    package func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "p" {
            let cleaned = textBuffer
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                segments.append(Segment(start: pStart, end: pEnd, text: cleaned))
            }
            inP = false
            textBuffer = ""
        }
    }
}

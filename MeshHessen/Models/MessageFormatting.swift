import Foundation

/// Inline Meshtastic text formatting (`**bold**`, `*italic*`, `~~strike~~`,
/// `` `code` ``, `[label](https://…)`), shared by message bubbles, the format
/// toolbar and notifications. Markers travel as plain text on the wire.
enum MessageFormatting {
    /// Link schemes that may become clickable. Message text comes from untrusted
    /// radio traffic, so everything else (javascript:, file:, mailto:, …) stays text.
    static let allowedLinkSchemes: Set<String> = ["http", "https"]

    private static let parsingOptions = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: false,
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible
    )

    private static let linkDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    // MARK: - Rendering

    /// Renders the inline formatting of `text`. Unmatched markers, whitespace and
    /// line breaks are kept; only http/https links carry a `.link` attribute;
    /// bare URLs outside code spans are linked as well.
    static func attributed(_ text: String) -> AttributedString {
        var result = (try? AttributedString(markdown: escapedForParsing(text), options: parsingOptions))
            ?? AttributedString(text)

        let disallowedLinks = result.runs.compactMap { run -> Range<Int>? in
            guard let url = run.link, !isAllowedLink(url) else { return nil }
            return offsets(of: run.range, in: result)
        }
        for range in disallowedLinks {
            result[indices(of: range, in: result)].link = nil
        }
        linkBareURLs(in: &result)
        return result
    }

    /// The text as it reads once the formatting markers are removed
    /// (for notification bodies and other plain-text surfaces).
    static func plainText(_ text: String) -> String {
        String(attributed(text).characters)
    }

    static func isAllowedLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowedLinkSchemes.contains(scheme)
    }

    // MARK: - Editing

    /// Wraps `selection` in `marker` on both sides. Without a selection the marker
    /// pair is appended at the end (`"abc"` → `"abc****"`). The returned selection
    /// covers the wrapped text (empty and between the markers when nothing was selected).
    static func wrap(
        _ text: String,
        selection: Range<String.Index>?,
        marker: String
    ) -> (text: String, selection: Range<String.Index>) {
        let range = selection ?? text.endIndex..<text.endIndex
        let prefix = String(text[..<range.lowerBound]) + marker
        let inner = String(text[range])
        let result = prefix + inner + marker + String(text[range.upperBound...])
        let start = result.index(result.startIndex, offsetBy: prefix.count)
        let end = result.index(start, offsetBy: inner.count)
        return (result, start..<end)
    }

    /// Inserts `[label](url)`. The label is the selected text, else `label`, else the
    /// URL itself. Without a selection the link is appended at the end, separated by
    /// a space from preceding text.
    static func insertLink(
        _ text: String,
        selection: Range<String.Index>?,
        url: String,
        label: String? = nil
    ) -> String {
        let selected = selection.map { String(text[$0]) } ?? ""
        let fallbackLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var linkLabel = !selected.isEmpty ? selected : (!fallbackLabel.isEmpty ? fallbackLabel : url)
        linkLabel = linkLabel.replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
        let link = "[\(linkLabel)](\(url))"

        if let selection {
            return String(text[..<selection.lowerBound]) + link + String(text[selection.upperBound...])
        }
        let separator = text.isEmpty || text.last?.isWhitespace == true ? "" : " "
        return text + separator + link
    }

    /// Normalises user input for the link button: trims, adds `https://` when no
    /// scheme is given and returns `nil` unless the result is an http/https URL with a host.
    static func normalizedLinkURL(_ input: String) -> String? {
        var candidate = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !candidate.contains(where: \.isWhitespace) else { return nil }
        if !candidate.contains("://") {
            // "javascript:…", "mailto:…": a scheme without "//" is never prefixed into a host.
            if let colon = candidate.firstIndex(of: ":"), !candidate[..<colon].contains(".") {
                return nil
            }
            candidate = "https://" + candidate
        }
        guard let url = URL(string: candidate),
              isAllowedLink(url),
              let host = url.host, !host.isEmpty else { return nil }
        return candidate
    }

    // MARK: - Private

    /// Escapes syntax the inline parser would otherwise turn into something that
    /// loses characters: images (`![…](…)`) and HTML entities (`&amp;`). Code spans
    /// are copied verbatim because backslashes are literal inside them.
    private static func escapedForParsing(_ text: String) -> String {
        guard text.contains("![") || text.contains("&") else { return text }
        let characters = Array(text)
        var output = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "`" {
                let runLength = backtickRunLength(in: characters, at: index)
                if let closing = closingBacktickRun(in: characters, from: index + runLength, length: runLength) {
                    output.append(contentsOf: characters[index..<(closing + runLength)])
                    index = closing + runLength
                } else {
                    output.append(contentsOf: characters[index..<(index + runLength)])
                    index += runLength
                }
                continue
            }
            if character == "!", index + 1 < characters.count, characters[index + 1] == "[" {
                output.append("!\\[")
                index += 2
                continue
            }
            if character == "&" {
                output.append("\\&")
            } else {
                output.append(character)
            }
            index += 1
        }
        return output
    }

    private static func backtickRunLength(in characters: [Character], at start: Int) -> Int {
        var end = start
        while end < characters.count, characters[end] == "`" { end += 1 }
        return end - start
    }

    private static func closingBacktickRun(in characters: [Character], from start: Int, length: Int) -> Int? {
        var index = start
        while index < characters.count {
            if characters[index] == "`" {
                let runLength = backtickRunLength(in: characters, at: index)
                if runLength == length { return index }
                index += runLength
            } else {
                index += 1
            }
        }
        return nil
    }

    /// Adds `.link` to bare http/https URLs in runs that are neither links nor code.
    private static func linkBareURLs(in attributed: inout AttributedString) {
        guard let detector = linkDetector else { return }
        var links: [(range: Range<Int>, url: URL)] = []
        for run in attributed.runs {
            guard run.link == nil else { continue }
            if let intent = run.inlinePresentationIntent, intent.contains(.code) { continue }
            let runText = String(attributed[run.range].characters)
            let runStart = offsets(of: run.range, in: attributed).lowerBound
            let nsRange = NSRange(runText.startIndex..., in: runText)
            for match in detector.matches(in: runText, range: nsRange) {
                guard let url = match.url, isAllowedLink(url),
                      let matchRange = Range(match.range, in: runText) else { continue }
                let lower = runStart + runText.distance(from: runText.startIndex, to: matchRange.lowerBound)
                links.append((lower..<(lower + runText[matchRange].count), url))
            }
        }
        for link in links {
            attributed[indices(of: link.range, in: attributed)].link = link.url
        }
    }

    /// Character offsets of `range`; stable across attribute-only mutations, unlike indices.
    private static func offsets(of range: Range<AttributedString.Index>, in text: AttributedString) -> Range<Int> {
        let characters = text.characters
        let lower = characters.distance(from: characters.startIndex, to: range.lowerBound)
        return lower..<(lower + characters.distance(from: range.lowerBound, to: range.upperBound))
    }

    private static func indices(of range: Range<Int>, in text: AttributedString) -> Range<AttributedString.Index> {
        let characters = text.characters
        let lower = characters.index(characters.startIndex, offsetBy: range.lowerBound)
        return lower..<characters.index(lower, offsetBy: range.count)
    }
}

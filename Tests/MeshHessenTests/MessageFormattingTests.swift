import Foundation
import Testing
@testable import MeshHessen

@Suite("Message formatting")
struct MessageFormattingTests {
    private struct RunInfo {
        let text: String
        let intent: InlinePresentationIntent?
        let link: URL?
    }

    private func runs(_ text: String) -> [RunInfo] {
        let attributed = MessageFormatting.attributed(text)
        return attributed.runs.map { run in
            RunInfo(
                text: String(attributed[run.range].characters),
                intent: run.inlinePresentationIntent,
                link: run.link
            )
        }
    }

    private func run(_ text: String, containing fragment: String) -> RunInfo? {
        runs(text).first { $0.text == fragment }
    }

    private func rendered(_ text: String) -> String {
        String(MessageFormatting.attributed(text).characters)
    }

    // MARK: - Inline styles

    @Test func boldItalicStrikeAndCode() throws {
        #expect(try #require(run("**a**", containing: "a")).intent?.contains(.stronglyEmphasized) == true)
        #expect(try #require(run("*a*", containing: "a")).intent?.contains(.emphasized) == true)
        #expect(try #require(run("~~a~~", containing: "a")).intent?.contains(.strikethrough) == true)
    }

    @Test func codeContentStaysLiteral() throws {
        let code = try #require(run("`a*b*`", containing: "a*b*"))
        #expect(code.intent?.contains(.code) == true)
        #expect(code.intent?.contains(.emphasized) != true)
    }

    @Test func nestedStyles() throws {
        let inner = try #require(run("**bold *both***", containing: "both"))
        #expect(inner.intent?.contains(.stronglyEmphasized) == true)
        #expect(inner.intent?.contains(.emphasized) == true)
    }

    // MARK: - Links

    @Test func httpsMarkdownLinkIsClickable() throws {
        let link = try #require(run("[x](https://example.org)", containing: "x"))
        #expect(link.link == URL(string: "https://example.org"))
    }

    @Test(arguments: ["[x](javascript:alert(1))", "[x](file:///etc/passwd)", "[x](mailto:a@b.org)"])
    func nonHTTPLinksAreNotClickable(_ text: String) {
        #expect(rendered(text) == "x")
        #expect(runs(text).allSatisfy { $0.link == nil })
    }

    @Test func bareURLIsClickable() throws {
        let link = try #require(run("see https://example.org now", containing: "https://example.org"))
        #expect(link.link == URL(string: "https://example.org"))
        #expect(rendered("see https://example.org now") == "see https://example.org now")
    }

    @Test func bareURLInsideBoldIsClickable() throws {
        let link = try #require(run("**https://example.org**", containing: "https://example.org"))
        #expect(link.link == URL(string: "https://example.org"))
        #expect(link.intent?.contains(.stronglyEmphasized) == true)
    }

    @Test func bareURLInsideCodeIsNotLinked() {
        #expect(runs("`https://example.org`").allSatisfy { $0.link == nil })
    }

    @Test func imageSyntaxStaysLiteral() {
        let text = "![img](https://example.org/a.png)"
        let attributed = MessageFormatting.attributed(text)
        #expect(String(attributed.characters) == text)
        #expect(attributed.runs.allSatisfy { $0.imageURL == nil })
    }

    @Test func imageSyntaxInsideCodeIsUnchanged() {
        #expect(rendered("`![a](b)`") == "![a](b)")
    }

    // MARK: - Literal text survives

    @Test(arguments: [
        "**unclosed",
        "CQ * 73 *",
        "5*5",
        "_underscores_in_names",
        "x_y_z",
        "line1\nline2",
        "a\n\nb",
        "  leading  spaces  ",
        "1. list",
        "# head",
        "> quote",
        "AT&T &amp; co",
        "path\\to\\file",
    ])
    func ordinaryTextIsPreserved(_ text: String) {
        #expect(rendered(text) == text)
    }

    @Test func plainTextStripsMarkers() {
        #expect(MessageFormatting.plainText("**Hi** *there* [map](https://x.org)") == "Hi there map")
    }

    // MARK: - Editing

    @Test func wrapWithoutSelectionAppendsMarkerPair() {
        let result = MessageFormatting.wrap("abc", selection: nil, marker: "**")
        #expect(result.text == "abc****")
        #expect(result.text.distance(from: result.text.startIndex, to: result.selection.lowerBound) == 5)
        #expect(result.selection.isEmpty)
    }

    @Test func wrapSelection() {
        let text = "say hello now"
        let lower = text.index(text.startIndex, offsetBy: 4)
        let upper = text.index(lower, offsetBy: 5)
        let result = MessageFormatting.wrap(text, selection: lower..<upper, marker: "~~")
        #expect(result.text == "say ~~hello~~ now")
        #expect(result.text[result.selection] == "hello")
    }

    @Test func insertLinkWithoutSelectionAppends() {
        #expect(MessageFormatting.insertLink("see", selection: nil, url: "https://x.org") == "see [https://x.org](https://x.org)")
        #expect(MessageFormatting.insertLink("", selection: nil, url: "https://x.org", label: "Map") == "[Map](https://x.org)")
    }

    @Test func insertLinkUsesSelectionAsLabel() {
        let text = "open map please"
        let lower = text.index(text.startIndex, offsetBy: 5)
        let upper = text.index(lower, offsetBy: 3)
        #expect(MessageFormatting.insertLink(text, selection: lower..<upper, url: "https://x.org")
            == "open [map](https://x.org) please")
    }

    @Test func normalizedLinkURL() {
        #expect(MessageFormatting.normalizedLinkURL(" example.org/a ") == "https://example.org/a")
        #expect(MessageFormatting.normalizedLinkURL("http://example.org") == "http://example.org")
        #expect(MessageFormatting.normalizedLinkURL("javascript:alert(1)") == nil)
        #expect(MessageFormatting.normalizedLinkURL("file:///etc/passwd") == nil)
        #expect(MessageFormatting.normalizedLinkURL("") == nil)
        #expect(MessageFormatting.normalizedLinkURL("two words") == nil)
    }
}

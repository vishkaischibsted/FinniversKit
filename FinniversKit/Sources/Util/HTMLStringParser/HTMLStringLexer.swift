import Foundation

public protocol HTMLStringLexerDelegate: AnyObject {
    func lexer(
        _ lexer: HTMLStringLexer,
        foundToken token: HTMLStringLexer.Token
    )
}

public final class HTMLStringLexer {
    public enum Token: Equatable {
        case beginTag(name: String, attributes: [String: String], isSelfClosing: Bool)
        case endTag(name: String)
        case commentTag(text: String)
        case documentTag(name: String, text: String)
        case text(String)
    }

    private struct TagMatch {
        let token: Token
        let range: Range<String.Index>
    }

    public weak var delegate: HTMLStringLexerDelegate?

    /**
     Regex pattern for HTML tag, like `<b>`, `</b>` and `<div foo="bar">`.

     Capture groups:
     1. End tag marker (optional)
     2. Tag name
     3. Attributes (optional)
     4. End tag marker for self-closed tag (optional)

     [RegExr test](https://regexr.com/70t11)
     */
    private let tagPattern = #"<(\/)?(\w+)((?:\s+[^\s=]+=(?:"[^"]*?"|(?:'[^']*?')))+)?\s*(\/)?>"#

    /**
     Regex pattern for HTML tag attribute, like `foo="bar"`.

     Capture groups:
     1. Name
     2. Value (ampersand `"` quoted)
     3. Value (apostrophe `'` quoted)

     [RegExr test](https://regexr.com/712ca)
     */
    private let tagAttributePattern = #"([^\s=]+)=(?:"([^"]*?)"|'([^']*?)')"#

    /**
     Regex pattern for HTML comment tag, like `<!-- foo -->`.

     Capture groups:
     1. Comment text, including whitespace

     [RegExr test](https://regexr.com/70ttk)
     */
    private let commentPattern = #"<!--(.*?)-->"#

    /**
     Regex pattern for HTML document tag, like `<!DOCUMENT HTML>`.

     Capture groups:
     1. Tag name
     2. Text (optional)

     [RegExr test](https://regexr.com/70ttq)
     */
    private let documentPattern = #"<!(\w+)(?:\s*>|\s+(.*?)\s*>)"#

    private let tagRegex: NSRegularExpression
    private let tagAttributeRegex: NSRegularExpression
    private let commentRegex: NSRegularExpression
    private let documentRegex: NSRegularExpression

    public init(delegate: HTMLStringLexerDelegate? = nil) {
        // The tag regex is predefined and validated, and should always compile
        // swiftlint:disable force_try
        self.tagRegex = try! NSRegularExpression(pattern: tagPattern, options: .dotMatchesLineSeparators)
        self.tagAttributeRegex = try! NSRegularExpression(pattern: tagAttributePattern, options: .dotMatchesLineSeparators)
        self.commentRegex = try! NSRegularExpression(pattern: commentPattern, options: .dotMatchesLineSeparators)
        self.documentRegex = try! NSRegularExpression(pattern: documentPattern, options: .dotMatchesLineSeparators)
        // swiftlint:enable force_try

        self.delegate = delegate
    }

    func read(html: String) {
        var foundTagMatch: TagMatch?
        var currentIndex = html.startIndex
        var lastTagRange = html.startIndex..<html.startIndex

        while currentIndex < html.endIndex {
            let currentCharacter = html[currentIndex]
            if currentCharacter != "<" {
                currentIndex = html.index(after: currentIndex)
                continue
            }

            // Look-ahead to discover <! tags
            let nextIndex = html.index(after: currentIndex)
            if nextIndex == html.endIndex {
                break
            }
            if html[nextIndex] == "!" {
                if let commentMatch = matchCommentTag(in: html, startIndex: currentIndex) {
                    foundTagMatch = commentMatch
                } else if let documentMatch = matchDocumentTag(in: html, startIndex: currentIndex) {
                    foundTagMatch = documentMatch
                }
            } else if let tagMatch = matchTag(in: html, startIndex: currentIndex) {
                foundTagMatch = tagMatch
            }

            if let tagMatch = foundTagMatch {
                let textBeforeTag = html[lastTagRange.upperBound..<currentIndex]
                emitText(textBeforeTag)
                emitToken(tagMatch.token)
                if case .beginTag(let name, _, let isSelfClosing) = tagMatch.token, isSelfClosing {
                    emitToken(.endTag(name: name))
                }
                currentIndex = tagMatch.range.upperBound
                foundTagMatch = nil
                lastTagRange = tagMatch.range
            } else {
                currentIndex = html.index(after: currentIndex)
            }
        }
        let remainingText = html[lastTagRange.upperBound..<html.endIndex]
        emitText(remainingText)
    }

    private func emitText(_ text: Substring) {
        if text.isEmpty { return }
        emitToken(.text(String(text)))
    }

    private func emitToken(_ token: Token) {
        delegate?.lexer(self, foundToken: token)
    }

    private func matchCommentTag(in searchString: String, startIndex: String.Index) -> TagMatch? {
        let nsRange = NSRange(startIndex..<searchString.endIndex, in: searchString)
        guard
            let match = commentRegex.firstMatch(in: searchString, range: nsRange),
            match.numberOfRanges == 2,
            let tagRange = Range(match.range(at: 0), in: searchString)
        else {
            return nil
        }
        var comment = ""
        if let commentRange = Range(match.range(at: 1), in: searchString) {
            comment.append(String(searchString[commentRange]))
        }
        return TagMatch(token: .commentTag(text: comment), range: tagRange)
    }

    private func matchDocumentTag(in searchString: String, startIndex: String.Index) -> TagMatch? {
        let nsRange = NSRange(startIndex..<searchString.endIndex, in: searchString)
        guard
            let match = documentRegex.firstMatch(in: searchString, range: nsRange),
            match.numberOfRanges == 3,
            let tagRange = Range(match.range(at: 0), in: searchString),
            let nameRange = Range(match.range(at: 1), in: searchString)
        else {
            return nil
        }
        let name = String(searchString[nameRange])
        var text = ""
        if let textRange = Range(match.range(at: 2), in: searchString) {
            text.append(String(searchString[textRange]))
        }
        return TagMatch(token: .documentTag(
            name: name,
            text: text
        ), range: tagRange)
    }

    private func matchTag(in searchString: String, startIndex: String.Index) -> TagMatch? {
        let nsRange = NSRange(startIndex..<searchString.endIndex, in: searchString)
        guard
            let match = tagRegex.firstMatch(in: searchString, range: nsRange),
            match.numberOfRanges == 5,
            let tagRange = Range(match.range(at: 0), in: searchString),
            let nameRange = Range(match.range(at: 2), in: searchString)
        else {
            return nil
        }
        let isEndTagNSRange = match.range(at: 1)
        let isEndTag = isEndTagNSRange.lowerBound != NSNotFound
        let name = String(searchString[nameRange])
        if isEndTag {
            return TagMatch(token: .endTag(name: name), range: tagRange)
        } else {
            var attributes: [String: String] = [:]
            let attributesNSRange = match.range(at: 3)
            if attributesNSRange.lowerBound != NSNotFound {
                for match in tagAttributeRegex.matches(in: searchString, range: attributesNSRange) {
                    guard
                        match.numberOfRanges == 4,
                        let nameRange = Range(match.range(at: 1), in: searchString)
                    else { continue }
                    let ampersandValueRange = Range(match.range(at: 2), in: searchString)
                    let apostropheValueRange = Range(match.range(at: 3), in: searchString)
                    var value = ""
                    if let valueRange = ampersandValueRange ?? apostropheValueRange {
                        value.append(String(searchString[valueRange]))
                    }
                    let name = String(searchString[nameRange])
                    attributes[name] = value
                }
            }
            let isSelfClosingNSRange = match.range(at: 4)
            let isSelfClosing = isSelfClosingNSRange.lowerBound != NSNotFound
            return TagMatch(token: .beginTag(
                name: name,
                attributes: attributes,
                isSelfClosing: isSelfClosing
            ), range: tagRange)
        }
    }
}

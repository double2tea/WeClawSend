import Foundation

/// The line-level formats understood by the text tools in a file basket.
public enum BasketTextLineKind: Equatable, Sendable {
    case plain
    case unchecked
    case checked
    case numbered
}

/// One visual line, using the same splitter as `toggleTodo` so reminder
/// checkboxes and editor transforms share indices.
public struct BasketTextParsedLine: Equatable, Sendable {
    public let kind: BasketTextLineKind
    public let indentation: String
    public let body: String
    public let raw: String

    public var isChecked: Bool? {
        switch kind {
        case .unchecked: false
        case .checked: true
        case .plain, .numbered: nil
        }
    }
}

/// Pure text transformations used by the basket text editor.
///
/// The transformations only operate on the supplied string. They do not read
/// the pasteboard, touch the file system, or apply regular expressions.
public enum BasketTextFormatting {
    public typealias LineKind = BasketTextLineKind

    /// Returns the format of one line, without its line-ending character.
    public static func parseLine(_ line: String) -> BasketTextLineKind {
        let parts = lineParts(for: line)
        return parts.kind
    }

    /// Labelled overload for callers that prefer an explicit line argument.
    public static func parseLine(line: String) -> BasketTextLineKind {
        parseLine(line)
    }

    /// Alias with a descriptive label for callers that prefer `kind(of:)`.
    public static func kind(of line: String) -> BasketTextLineKind {
        parseLine(line)
    }

    /// Splits `text` the same way `toggleTodo` does, including CRLF handling
    /// and not inventing a trailing empty line after a final newline.
    public static func parsedLines(_ text: String) -> [BasketTextParsedLine] {
        splitLines(text).map { line in
            let parts = lineParts(for: line.content)
            return BasketTextParsedLine(
                kind: parts.kind,
                indentation: parts.indentation,
                body: parts.body,
                raw: line.content
            )
        }
    }

    /// Converts each non-blank line to an unchecked checklist item.
    /// Existing checklist items keep their checked state. Existing numbered
    /// items have their number removed before the checklist marker is added.
    public static func makeChecklist(_ text: String) -> String {
        transform(text) { line in
            guard !isBlank(line.content) else { return line.content }

            let parts = lineParts(for: line.content)
            let marker = parts.kind == .checked ? "- [x] " : "- [ ] "
            return parts.indentation + marker + parts.body
        }
    }

    /// Labelled overload for use from SwiftUI actions and tests.
    public static func makeChecklist(text: String) -> String {
        makeChecklist(text)
    }

    /// Numbers each non-blank line from one. Blank lines and their positions
    /// are retained; existing checklist and numbered prefixes are replaced.
    public static func makeNumbered(_ text: String) -> String {
        var number = 1
        return transform(text) { line in
            guard !isBlank(line.content) else { return line.content }

            let parts = lineParts(for: line.content)
            defer { number += 1 }
            return parts.indentation + "\(number). " + parts.body
        }
    }

    /// Labelled overload for use from SwiftUI actions and tests.
    public static func makeNumbered(text: String) -> String {
        makeNumbered(text)
    }

    /// Stable-sorts every contiguous checklist block, leaving unchecked items
    /// before checked items. Blank lines and non-checklist paragraphs are not
    /// moved.
    public static func sortChecklist(_ text: String) -> String {
        var lines = splitLines(text)
        var blockStart = 0

        while blockStart < lines.count {
            guard isChecklist(lines[blockStart].content) else {
                blockStart += 1
                continue
            }

            var blockEnd = blockStart + 1
            while blockEnd < lines.count, isChecklist(lines[blockEnd].content) {
                blockEnd += 1
            }
            stableSortChecklistBlock(&lines, from: blockStart, to: blockEnd)
            blockStart = blockEnd
        }

        return joinLines(lines)
    }

    /// Labelled overload for callers that prefer an explicit text argument.
    public static func sortChecklist(text: String) -> String {
        sortChecklist(text)
    }

    /// Toggles one zero-based line in a checklist. When requested, only the
    /// contiguous checklist block containing that line is stably sorted after
    /// the toggle; surrounding paragraphs and blocks remain in place.
    public static func toggleTodo(
        _ text: String,
        lineIndex: Int,
        moveCompletedToEnd: Bool = true
    ) -> String {
        var lines = splitLines(text)
        guard lines.indices.contains(lineIndex) else { return text }

        let parts = lineParts(for: lines[lineIndex].content)
        guard parts.kind == .unchecked || parts.kind == .checked else { return text }

        let marker = parts.kind == .unchecked ? "- [x] " : "- [ ] "
        lines[lineIndex].content = parts.indentation + marker + parts.body

        guard moveCompletedToEnd else { return joinLines(lines) }

        var blockStart = lineIndex
        while blockStart > 0, isChecklist(lines[blockStart - 1].content) {
            blockStart -= 1
        }
        var blockEnd = lineIndex + 1
        while blockEnd < lines.count, isChecklist(lines[blockEnd].content) {
            blockEnd += 1
        }
        stableSortChecklistBlock(&lines, from: blockStart, to: blockEnd)
        return joinLines(lines)
    }

    /// Labelled overload for callers that prefer an explicit text argument.
    public static func toggleTodo(
        text: String,
        lineIndex: Int,
        moveCompletedToEnd: Bool = true
    ) -> String {
        toggleTodo(text, lineIndex: lineIndex, moveCompletedToEnd: moveCompletedToEnd)
    }

    private struct Line {
        var content: String
        let separator: String
    }

    private struct Parts {
        let kind: BasketTextLineKind
        let indentation: String
        let body: String
    }

    private static func transform(_ text: String, _ body: (Line) -> String) -> String {
        joinLines(splitLines(text).map { line in
            var transformed = line
            transformed.content = body(line)
            return transformed
        })
    }

    private static func lineParts(for line: String) -> Parts {
        let characters = Array(line)
        var indentationEnd = 0
        while indentationEnd < characters.count, isIndentation(characters[indentationEnd]) {
            indentationEnd += 1
        }

        let indentation = String(characters[..<indentationEnd])
        let remainder = String(characters[indentationEnd...])

        if let body = checklistBody(in: remainder, checked: false) {
            return Parts(kind: .unchecked, indentation: indentation, body: body)
        }
        if let body = checklistBody(in: remainder, checked: true) {
            return Parts(kind: .checked, indentation: indentation, body: body)
        }
        if let body = numberedBody(in: remainder) {
            return Parts(kind: .numbered, indentation: indentation, body: body)
        }
        return Parts(kind: .plain, indentation: indentation, body: remainder)
    }

    private static func checklistBody(in remainder: String, checked: Bool) -> String? {
        let marker = checked ? "- [x]" : "- [ ]"
        let alternateMarker = checked ? "- [X]" : marker
        let matchedMarker: String
        if remainder.hasPrefix(marker) {
            matchedMarker = marker
        } else if remainder.hasPrefix(alternateMarker) {
            matchedMarker = alternateMarker
        } else {
            return nil
        }

        let suffix = remainder.dropFirst(matchedMarker.count)
        guard suffix.isEmpty || suffix.first?.isWhitespace == true else { return nil }
        return stripMarkerWhitespace(from: String(suffix))
    }

    private static func numberedBody(in remainder: String) -> String? {
        let characters = Array(remainder)
        var index = 0
        while index < characters.count, isASCIIDigit(characters[index]) {
            index += 1
        }
        guard index > 0, index < characters.count else { return nil }
        guard characters[index] == "." || characters[index] == ")" else { return nil }
        index += 1
        guard index == characters.count || characters[index].isWhitespace else { return nil }
        while index < characters.count, characters[index].isWhitespace {
            index += 1
        }
        return String(characters[index...])
    }

    private static func stripMarkerWhitespace(from suffix: String) -> String {
        var characters = Array(suffix)
        while let first = characters.first, isIndentation(first) {
            characters.removeFirst()
        }
        return String(characters)
    }

    private static func isChecklist(_ line: String) -> Bool {
        let kind = parseLine(line)
        return kind == .unchecked || kind == .checked
    }

    private static func stableSortChecklistBlock(_ lines: inout [Line], from start: Int, to end: Int) {
        guard end - start > 1 else { return }
        let contents = lines[start..<end].map(\.content)
        let sorted = contents.filter { parseLine($0) == .unchecked }
            + contents.filter { parseLine($0) == .checked }
        for offset in 0..<(end - start) {
            lines[start + offset].content = sorted[offset]
        }
    }

    private static func splitLines(_ text: String) -> [Line] {
        // Unicode scalars, not Character: Swift treats "\r\n" as one grapheme,
        // so a Character walk would keep Windows line endings inside the body.
        let scalars = text.unicodeScalars
        guard !scalars.isEmpty else { return [] }

        var lines: [Line] = []
        var content = String.UnicodeScalarView()
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "\r" {
                let next = scalars.index(after: index)
                if next < scalars.endIndex, scalars[next] == "\n" {
                    lines.append(Line(content: String(content), separator: "\r\n"))
                    content.removeAll(keepingCapacity: true)
                    index = scalars.index(after: next)
                    continue
                }
                lines.append(Line(content: String(content), separator: "\r"))
                content.removeAll(keepingCapacity: true)
                index = next
                continue
            }
            if scalar == "\n" {
                lines.append(Line(content: String(content), separator: "\n"))
                content.removeAll(keepingCapacity: true)
                index = scalars.index(after: index)
                continue
            }
            content.append(scalar)
            index = scalars.index(after: index)
        }
        if !content.isEmpty {
            lines.append(Line(content: String(content), separator: ""))
        }
        return lines
    }

    private static func joinLines(_ lines: [Line]) -> String {
        lines.map { $0.content + $0.separator }.joined()
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy(\.isWhitespace)
    }

    private static func isIndentation(_ character: Character) -> Bool {
        character == " " || character == "\t"
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character >= "0" && character <= "9"
    }
}

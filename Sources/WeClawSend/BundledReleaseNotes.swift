import Foundation

enum BundledReleaseNotes {
    static func notes(for version: String, bundle: Bundle = .main) -> [String] {
        guard let url = bundle.url(forResource: "RELEASE_NOTES", withExtension: "md"),
              let markdown = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return notes(in: markdown, for: version)
    }

    static func notes(in markdown: String, for version: String) -> [String] {
        let expectedHeading = "# v\(version)"
        var isCurrentSection = false
        var notes: [String] = []

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("# ") {
                if isCurrentSection { break }
                isCurrentSection = line == expectedHeading
                    || line.hasPrefix(expectedHeading + " ")
                continue
            }
            guard isCurrentSection, line.hasPrefix("- ") else { continue }
            let note = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if !note.isEmpty {
                notes.append(note)
            }
        }
        return notes
    }
}

import Foundation

/// Readable release-note excerpts, not a complete Markdown renderer.
enum AppUpdateReleaseNotes {
    static func plainText(_ markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var output: [String] = []
        var fence: (marker: Character, length: Int)?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let active = fence {
                let run = trimmed.prefix { $0 == active.marker }
                if run.count >= active.length && trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty {
                    fence = nil
                } else {
                    output.append(line)
                }
                continue
            }
            if let first = trimmed.first, first == "`" || first == "~" {
                let run = trimmed.prefix { $0 == first }
                if run.count >= 3 {
                    fence = (first, run.count)
                    continue
                }
            }
            if !output.isEmpty, !output[output.count - 1].trimmingCharacters(in: .whitespaces).isEmpty,
               trimmed.range(of: #"^(?:=+|-+)$"#, options: .regularExpression) != nil {
                continue
            }
            var text = line
            if text.range(of: #"^ {0,3}#{1,6}(?:\s+|$)"#, options: .regularExpression) != nil {
                text = text.replacingOccurrences(of: #"^ {0,3}#{1,6}(?:\s+|$)"#, with: "", options: .regularExpression)
                text = text.replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
            }
            text = text.replacingOccurrences(of: #"^([ \t]*)[-+*][ \t]+"#, with: "$1• ", options: .regularExpression)
            output.append(inlineText(text))
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Protect code and addresses before removing emphasis, including underscores
    // in URLs and literal Markdown inside inline code. Balanced URL parentheses
    // are supported for common release links; unrecognized syntax is left intact.
    private static let inlineTokens = try! NSRegularExpression(
        pattern: #"(?<!`)(`+)(.+?)\1(?!`)|\[([^\]\n]+)\]\(((?:[^()\s]|\([^()\s]*\))+)\)|(https?://\S+)"#)

    private static func inlineText(_ line: String) -> String {
        var marker = "\u{E000}"
        while line.contains(marker) { marker += "\u{E000}" }
        var protected: [(String, String)] = []
        var text = line
        let source = line as NSString
        for match in inlineTokens.matches(in: line, range: NSRange(location: 0, length: source.length)).reversed() {
            let literal: String
            if match.range(at: 2).location != NSNotFound {
                literal = source.substring(with: match.range(at: 2))
            } else if match.range(at: 3).location != NSNotFound {
                literal = emphasis(source.substring(with: match.range(at: 3))) + "（" + source.substring(with: match.range(at: 4)) + "）"
            } else {
                literal = source.substring(with: match.range(at: 5))
            }
            let token = marker + String(protected.count) + marker
            protected.append((token, literal))
            if let range = Range(match.range, in: text) { text.replaceSubrange(range, with: token) }
        }
        text = emphasis(text)
        for (token, literal) in protected { text = text.replacingOccurrences(of: token, with: literal) }
        return text
    }

    private static func emphasis(_ text: String) -> String {
        var result = text
        for pattern in [
            #"\*\*(\S(?:.*?\S)?)\*\*"#,
            #"(?<![\p{L}\p{N}_])__(\S(?:.*?\S)?)__(?![\p{L}\p{N}_])"#,
            #"(?<![\p{L}\p{N}_])_(\S(?:.*?\S)?)_(?![\p{L}\p{N}_])"#,
            #"(?<![\p{L}\p{N}*])\*(\S(?:.*?\S)?)\*(?![\p{L}\p{N}*])"#
        ] {
            result = result.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
        }
        return result
    }
}

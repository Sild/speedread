import Foundation

enum SpeedTokenizer {
    struct OptimalRecognitionParts: Equatable, Sendable {
        let prefix: String
        let focus: String
        let suffix: String
        let wordGraphemeCount: Int
    }

    static func tokenize(_ element: SpeedContentElement) -> [SpeedToken] {
        var tokens: [SpeedToken] = []
        for segment in element.segments {
            var offset = segment.tokenOffsetBase
            for paragraph in segment.text.split(whereSeparator: \Character.isNewline) {
                let words = paragraph.split(whereSeparator: \Character.isWhitespace)
                for (wordIndex, wordSlice) in words.enumerated() {
                    let word = String(wordSlice)
                    let parts = optimalRecognitionParts(for: word)
                    tokens.append(
                        SpeedToken(
                            elementID: segment.id,
                            offset: offset,
                            text: word,
                            prefix: parts.prefix,
                            focus: parts.focus,
                            suffix: parts.suffix,
                            locatorJSON: tokenLocatorJSON(
                                baseLocatorJSON: segment.locatorJSON,
                                sourceText: segment.text,
                                word: word,
                                range: wordSlice.startIndex ..< wordSlice.endIndex
                            ),
                            totalProgression: segment.totalProgression,
                            endsParagraph: wordIndex == words.count - 1,
                            wordGraphemeCount: parts.wordGraphemeCount
                        )
                    )
                    offset += 1
                }
            }
        }
        return tokens
    }

    private static func tokenLocatorJSON(
        baseLocatorJSON: String,
        sourceText: String,
        word: String,
        range: Range<String.Index>?
    ) -> String {
        guard let range,
              let data = baseLocatorJSON.data(using: .utf8),
              var locator = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return baseLocatorJSON
        }

        let existingText = locator["text"] as? [String: Any]
        let originalBefore = existingText?["before"] as? String ?? ""
        let originalAfter = existingText?["after"] as? String ?? ""
        let beforeSource = originalBefore + String(sourceText[..<range.lowerBound])
        let afterSource = String(sourceText[range.upperBound...]) + originalAfter
        let before = String(beforeSource.suffix(96))
        let after = String(afterSource.prefix(96))
        var text: [String: Any] = ["highlight": word]
        if !before.isEmpty {
            text["before"] = before
        }
        if !after.isEmpty {
            text["after"] = after
        }
        locator["text"] = text

        guard JSONSerialization.isValidJSONObject(locator),
              let serialized = try? JSONSerialization.data(
                  withJSONObject: locator,
                  options: [.sortedKeys]
              ),
              let locatorJSON = String(data: serialized, encoding: .utf8)
        else {
            return baseLocatorJSON
        }
        return locatorJSON
    }

    static func optimalRecognitionParts(
        for token: String
    ) -> OptimalRecognitionParts {
        let graphemes = Array(token)
        guard !graphemes.isEmpty else {
            return OptimalRecognitionParts(prefix: "", focus: "", suffix: "", wordGraphemeCount: 0)
        }

        let wordIndices = graphemes.indices.filter { graphemes[$0].isLetterOrNumber }
        let firstWordIndex = wordIndices.first ?? graphemes.startIndex
        let lastWordIndex = wordIndices.last ?? firstWordIndex
        let wordLength = wordIndices.isEmpty ? 1 : wordIndices.count
        let recognitionOffset = switch wordLength {
        case ...1: 0
        case 2 ... 5: 1
        case 6 ... 9: 2
        case 10 ... 13: 3
        default: 4
        }
        let focusIndex = min(firstWordIndex + recognitionOffset, lastWordIndex)
        return OptimalRecognitionParts(
            prefix: String(graphemes[..<focusIndex]),
            focus: String(graphemes[focusIndex]),
            suffix: String(graphemes[(focusIndex + 1)...]),
            wordGraphemeCount: wordIndices.isEmpty ? 0 : wordLength
        )
    }
}

enum SpeedPacing {
    static func durationMilliseconds(
        for token: SpeedToken,
        settings: SpeedReaderSettings
    ) -> Int64 {
        let base = 60000.0 / Double(settings.normalizedWordsPerMinute)
        guard settings.adaptivePauses else {
            return Int64(base.rounded())
        }

        var multiplier = token.wordGraphemeCount >= 10 ? 1.25 : 1
        if let punctuation = token.trailingPunctuation {
            if ".!?…".contains(punctuation) {
                multiplier = max(multiplier, 2)
            } else if ",:;—–".contains(punctuation) {
                multiplier = max(multiplier, 1.5)
            }
        }
        if token.endsParagraph {
            multiplier = max(multiplier, 2.5)
        }
        return Int64((base * multiplier).rounded())
    }
}

private extension Character {
    var isLetterOrNumber: Bool {
        unicodeScalars.contains {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }
    }
}

private extension SpeedToken {
    var trailingPunctuation: Character? {
        let ignoredClosers = CharacterSet(charactersIn: "\"'”’)]}»")
        return text.reversed().first { character in
            !character.unicodeScalars.allSatisfy(ignoredClosers.contains)
        }
    }
}

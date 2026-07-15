import Foundation

struct NormalizedRect: Codable, Equatable, Sendable {
    let left: Double
    let top: Double
    let width: Double
    let height: Double

    var maxX: Double {
        left + width
    }

    var maxY: Double {
        top + height
    }

    var midX: Double {
        left + width / 2
    }

    var midY: Double {
        top + height / 2
    }
}

struct PDFTextLine: Equatable, Sendable {
    let text: String
    let rect: NormalizedRect
    let confidence: Float
}

enum PDFTextLayout {
    private static let maximumFragmentGap = 0.045
    private static let minimumColumnLines = 3

    static func assembleOCRLines(_ observations: [PDFTextLine]) -> [PDFTextLine] {
        var rows: [[PDFTextLine]] = []
        for observation in sort(observations) {
            if let rowIndex = rows.indices.reversed().first(where: { index in
                rows[index].contains { sharesBaseline($0, observation) }
            }) {
                rows[rowIndex].append(observation)
            } else {
                rows.append([observation])
            }
        }

        return rows.flatMap { row -> [PDFTextLine] in
            let fragments = row.sorted { $0.rect.left < $1.rect.left }
            guard let first = fragments.first else {
                return [PDFTextLine]()
            }
            var result: [PDFTextLine] = []
            var current = first
            for fragment in fragments.dropFirst() {
                let gap = fragment.rect.left - current.rect.maxX
                let allowedGap = min(
                    maximumFragmentGap,
                    max(current.rect.height, fragment.rect.height) * 2.5
                )
                if gap <= allowedGap {
                    current = merge(current, fragment)
                } else {
                    result.append(current)
                    current = fragment
                }
            }
            result.append(current)
            return result
        }
    }

    static func orderedLines(_ lines: [PDFTextLine]) -> [PDFTextLine]? {
        let sortedLines = sort(lines)
        let left = lines.filter { $0.rect.maxX <= 0.48 && $0.rect.width < 0.55 }
        let right = lines.filter { $0.rect.left >= 0.52 && $0.rect.width < 0.55 }
        guard left.count >= minimumColumnLines, right.count >= minimumColumnLines else {
            return sortedLines
        }

        let medianHeight = lines.map(\.rect.height).sorted()[lines.count / 2]
        guard hasSustainedColumnRows(left: left, right: right, medianHeight: medianHeight) else {
            return sortedLines
        }

        let columnStart = max(
            left.map(\.rect.top).min() ?? 1,
            right.map(\.rect.top).min() ?? 1
        )
        let columnEnd = min(
            left.map(\.rect.maxY).max() ?? 0,
            right.map(\.rect.maxY).max() ?? 0
        )
        guard columnEnd - columnStart >= medianHeight * 2 else {
            return sortedLines
        }

        let columnLines = left + right
        let spanning = lines.filter { !columnLines.containsTextLine($0) }
        let overlapping = spanning.filter {
            $0.rect.maxY > columnStart && $0.rect.top < columnEnd
        }
        guard overlapping.isEmpty else {
            return nil
        }

        let topSpanning = spanning.filter { $0.rect.midY <= columnStart }
        let bottomSpanning = spanning.filter { !topSpanning.containsTextLine($0) }
        return sort(topSpanning) + sort(left) + sort(right) + sort(bottomSpanning)
    }

    static func isTableLike(_ lines: [PDFTextLine]) -> Bool {
        guard lines.count >= 8 else {
            return false
        }
        let shortLines = lines.count { line in
            line.text.split(whereSeparator: \.isWhitespace).count <= 2
        }
        return Double(shortLines) / Double(lines.count) > 0.60
    }

    static func join(_ lines: [PDFTextLine]) -> String {
        guard let first = lines.first else {
            return ""
        }
        let medianHeight = lines.map(\.rect.height).sorted()[lines.count / 2]
        var result = first.text.trimmingCharacters(in: .whitespacesAndNewlines)

        for pair in zip(lines, lines.dropFirst()) {
            let current = pair.0
            let next = pair.1
            let nextText = next.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !nextText.isEmpty else {
                continue
            }
            let verticalGap = next.rect.top - current.rect.maxY
            let columnRestart = verticalGap < -medianHeight
            let paragraphBreak = columnRestart
                || verticalGap > medianHeight * 1.6
                || abs(next.rect.left - current.rect.left) > 0.08

            if !paragraphBreak, result.last == "-", nextText.first?.isLowercase == true {
                result.removeLast()
                result += nextText
            } else {
                result += paragraphBreak ? "\n\n" : " "
                result += nextText
            }
        }
        return result
    }

    private static func sort(_ lines: [PDFTextLine]) -> [PDFTextLine] {
        lines.sorted {
            if abs($0.rect.top - $1.rect.top) > 0.01 {
                return $0.rect.top < $1.rect.top
            }
            return $0.rect.left < $1.rect.left
        }
    }

    private static func sharesBaseline(_ left: PDFTextLine, _ right: PDFTextLine) -> Bool {
        let overlap = min(left.rect.maxY, right.rect.maxY) - max(left.rect.top, right.rect.top)
        let minimumHeight = min(left.rect.height, right.rect.height)
        if overlap >= minimumHeight * 0.5 {
            return true
        }
        return abs(left.rect.midY - right.rect.midY)
            <= max(left.rect.height, right.rect.height) * 0.35
    }

    private static func hasSustainedColumnRows(
        left: [PDFTextLine],
        right: [PDFTextLine],
        medianHeight: Double
    ) -> Bool {
        let baselineTolerance = max(medianHeight * 1.75, 0.008)
        let maximumRowGap = max(medianHeight * 3, 0.025)
        let matchedRows = left.compactMap { leftLine -> Double? in
            let nearestDistance = right.map { abs($0.rect.midY - leftLine.rect.midY) }.min()
            guard let nearestDistance, nearestDistance <= baselineTolerance else {
                return nil
            }
            return leftLine.rect.midY
        }.sorted()

        var runLength = 1
        for pair in zip(matchedRows, matchedRows.dropFirst()) {
            runLength = pair.1 - pair.0 <= maximumRowGap ? runLength + 1 : 1
            if runLength >= minimumColumnLines {
                return true
            }
        }
        return false
    }

    private static func merge(_ left: PDFTextLine, _ right: PDFTextLine) -> PDFTextLine {
        let leftCount = max(characterCount(left.text), 1)
        let rightCount = max(characterCount(right.text), 1)
        let totalCount = leftCount + rightCount
        let confidence = (
            left.confidence * Float(leftCount) + right.confidence * Float(rightCount)
        ) / Float(totalCount)
        let minLeft = min(left.rect.left, right.rect.left)
        let minTop = min(left.rect.top, right.rect.top)
        let maxRight = max(left.rect.maxX, right.rect.maxX)
        let maxBottom = max(left.rect.maxY, right.rect.maxY)
        return PDFTextLine(
            text: "\(left.text) \(right.text)",
            rect: NormalizedRect(
                left: minLeft,
                top: minTop,
                width: maxRight - minLeft,
                height: maxBottom - minTop
            ),
            confidence: confidence
        )
    }

    private static func characterCount(_ text: String) -> Int {
        text.unicodeScalars.count { CharacterSet.alphanumerics.contains($0) }
    }
}

private extension [PDFTextLine] {
    func containsTextLine(_ candidate: PDFTextLine) -> Bool {
        contains { $0.text == candidate.text && $0.rect == candidate.rect }
    }
}

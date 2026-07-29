import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit

enum FixtureFailure: Error {
    case contextCreation
    case documentCreation
    case imageCreation
    case writeFailure(String)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let pageSize = CGSize(width: 612, height: 792)

func drawText(_ text: String, in rect: CGRect, context: CGContext, fontSize: CGFloat = 18) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize),
        .foregroundColor: NSColor.black
    ]
    let framesetter = CTFramesetterCreateWithAttributedString(
        NSAttributedString(string: text, attributes: attributes)
    )
    let path = CGPath(rect: rect, transform: nil)
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
    context.saveGState()
    context.textMatrix = .identity
    CTFrameDraw(frame, context)
    context.restoreGState()
}

func createPDF(
    at url: URL,
    pages: (_ page: Int, _ context: CGContext) -> Void,
    pageCount: Int = 1,
    metadata: [CFString: Any]? = nil
) throws {
    guard let consumer = CGDataConsumer(url: url as CFURL) else {
        throw FixtureFailure.contextCreation
    }
    var mediaBox = CGRect(origin: .zero, size: pageSize)
    guard let context = CGContext(
        consumer: consumer,
        mediaBox: &mediaBox,
        metadata as CFDictionary?
    ) else {
        throw FixtureFailure.contextCreation
    }
    for page in 0 ..< pageCount {
        context.beginPDFPage(nil as CFDictionary?)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(mediaBox)
        pages(page, context)
        context.endPDFPage()
    }
    context.closePDF()
}

func addOutlineAndWriteOptions(
    source: URL,
    destination: URL,
    title: String? = nil,
    author: String? = nil,
    outlineTitles: [String] = [],
    options: [PDFDocumentWriteOption: Any] = [:]
) throws {
    guard let document = PDFDocument(url: source) else {
        throw FixtureFailure.documentCreation
    }
    if title != nil || author != nil {
        var attributes = document.documentAttributes ?? [:]
        if let title {
            attributes[PDFDocumentAttribute.titleAttribute] = title
        }
        if let author {
            attributes[PDFDocumentAttribute.authorAttribute] = author
        }
        document.documentAttributes = attributes
    }
    if !outlineTitles.isEmpty {
        let root = PDFOutline()
        for (index, outlineTitle) in outlineTitles.enumerated() {
            guard let page = document.page(at: min(index, document.pageCount - 1)) else {
                continue
            }
            let child = PDFOutline()
            child.label = outlineTitle
            child.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: pageSize.height))
            root.insertChild(child, at: root.numberOfChildren)
        }
        document.outlineRoot = root
    }
    guard document.write(to: destination, withOptions: options) else {
        throw FixtureFailure.writeFailure(destination.path)
    }
}

func temporaryURL(_ name: String) -> URL {
    outputDirectory.appendingPathComponent(".\(name)-source.pdf")
}

func fixtureURL(_ name: String) -> URL {
    outputDirectory.appendingPathComponent("\(name).pdf")
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let metadataSource = temporaryURL("pdf-metadata-outline")
try createPDF(at: metadataSource, pages: { page, context in
    let text = page == 0
        ? "Chapter One\nNative PDF reading preserves this embedded Latin text and its page locator."
        : "Chapter Two\nThe second page verifies outline navigation and adjacent-page extraction."
    drawText(text, in: CGRect(x: 54, y: 90, width: 504, height: 620), context: context)
}, pageCount: 2)
try addOutlineAndWriteOptions(
    source: metadataSource,
    destination: fixtureURL("pdf-metadata-outline"),
    title: "Native PDF Fixture",
    author: "SpeedRead Tests",
    outlineTitles: ["Chapter One", "Chapter Two"]
)

try createPDF(at: fixtureURL("pdf-missing-metadata"), pages: { _, context in
    drawText(
        "A deterministic PDF without title or author metadata uses its filename as the title.",
        in: CGRect(x: 54, y: 90, width: 504, height: 620),
        context: context
    )
})

try createPDF(at: fixtureURL("pdf-cyrillic"), pages: { _, context in
    drawText(
        "Первая страница\nСкорочтение сохраняет контекст и корректно обрабатывает кириллический текст.",
        in: CGRect(x: 54, y: 90, width: 504, height: 620),
        context: context
    )
})

try createPDF(at: fixtureURL("pdf-two-column"), pages: { _, context in
    drawText(
        "Left column begins with complete prose. It continues in stable reading order across several clear lines.",
        in: CGRect(x: 48, y: 110, width: 230, height: 570),
        context: context,
        fontSize: 15
    )
    drawText(
        "Right column follows after the left column. Its separation is wide enough to remain unambiguous.",
        in: CGRect(x: 334, y: 110, width: 230, height: 570),
        context: context,
        fontSize: 15
    )
})

try createPDF(at: fixtureURL("pdf-ambiguous-layout"), pages: { _, context in
    drawText(
        "A narrow left fragment overlaps a central prose block and makes the intended reading order ambiguous.",
        in: CGRect(x: 48, y: 110, width: 245, height: 570),
        context: context,
        fontSize: 15
    )
    drawText(
        "This crossing fragment occupies the center while another right-side block competes for ordering.",
        in: CGRect(x: 230, y: 170, width: 250, height: 520),
        context: context,
        fontSize: 15
    )
    drawText(
        "The right fragment cannot be safely sequenced without guessing at the source layout.",
        in: CGRect(x: 370, y: 110, width: 190, height: 570),
        context: context,
        fontSize: 15
    )
})

try createPDF(at: fixtureURL("pdf-long"), pages: { page, context in
    drawText(
        "Page \(page + 1)\nThis long deterministic document exercises bounded page extraction, adjacent prefetch, cache reuse, seeking, and stable PDF locators without materializing the whole publication.",
        in: CGRect(x: 54, y: 90, width: 504, height: 620),
        context: context
    )
}, pageCount: 40)

func makeScannedImage() throws -> CGImage {
    let width = 1_200
    let height = 1_600
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw FixtureFailure.contextCreation
    }
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    drawText(
        "Scanned page\nAccurate local optical character recognition recovers this clear image-only prose while the original PDF remains unchanged.",
        in: CGRect(x: 90, y: 200, width: 1_020, height: 1_100),
        context: context,
        fontSize: 42
    )
    guard let image = context.makeImage() else {
        throw FixtureFailure.imageCreation
    }
    return image
}

let scannedImage = try makeScannedImage()
try createPDF(at: fixtureURL("pdf-image-only"), pages: { _, context in
    context.draw(scannedImage, in: CGRect(origin: .zero, size: pageSize))
})
try createPDF(at: fixtureURL("pdf-long-scanned"), pages: { _, context in
    context.draw(scannedImage, in: CGRect(origin: .zero, size: pageSize))
}, pageCount: 40)

let lockedSource = temporaryURL("pdf-password-locked")
try createPDF(at: lockedSource, pages: { _, context in
    drawText(
        "Password-protected content remains unavailable until explicit password support exists.",
        in: CGRect(x: 54, y: 90, width: 504, height: 620),
        context: context
    )
})
try addOutlineAndWriteOptions(
    source: lockedSource,
    destination: fixtureURL("pdf-password-locked"),
    options: [
        .ownerPasswordOption: "fixture-owner",
        .userPasswordOption: "fixture-user"
    ]
)

let restrictedSource = temporaryURL("pdf-copy-restricted")
try createPDF(at: restrictedSource, pages: { _, context in
    drawText(
        "This PDF remains readable but its permissions prohibit content extraction for speed mode.",
        in: CGRect(x: 54, y: 90, width: 504, height: 620),
        context: context
    )
})
let nonCopyingPermissionsRawValue = PDFAccessPermissions.allowsLowQualityPrinting.rawValue
    | PDFAccessPermissions.allowsContentAccessibility.rawValue
try addOutlineAndWriteOptions(
    source: restrictedSource,
    destination: fixtureURL("pdf-copy-restricted"),
    options: [
        .ownerPasswordOption: "fixture-owner",
        .accessPermissionsOption: NSNumber(value: nonCopyingPermissionsRawValue)
    ]
)

try Data("not a valid PDF".utf8).write(to: fixtureURL("pdf-malformed"), options: .atomic)

for temporary in [metadataSource, lockedSource, restrictedSource] {
    try? FileManager.default.removeItem(at: temporary)
}

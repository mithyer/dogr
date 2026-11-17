// Makes the QR code of the home page as a static SVG, and checks that a scanner can read it back.
//
//   swift tools/make-qr.swift make  <text> <out.svg>     write the SVG
//   swift tools/make-qr.swift check <picture> <text>     read a picture (PNG or JPEG) and compare what it holds with <text>
//
// The page points its QR code at https://dogr.dev/get, not at the App Store address itself: the Worker (worker.js) answers
// /get with a redirect, so the address can change later (TestFlight, store, another country) and the printed or published
// code keeps working. The result is committed as site/img/qr-get.svg; run this again only when the text changes.
//
// It uses only what macOS ships (CoreImage), so there is nothing to install. The matrix comes from CoreImage's own generator,
// one pixel per module, and is written out as ONE path of horizontal runs, with the four-module quiet zone the standard asks
// for and a white background, so the code reads the same on the cream page and on the dark download band.
// TEST:tests/site.test.mjs[the QR code of the home page is a valid static SVG]
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// The colour of the dark modules: the deep green of the page's ink, dark enough for any scanner.
let moduleColor = "#23413b"
/// The empty border around the code, in modules (the QR standard asks for four).
let quietZone = 4

/// Prints a message on standard error and stops with a failure status.
/// - Parameter message: What went wrong.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Builds the module matrix of a QR code.
/// - Parameter text: The text to encode (UTF-8).
/// - Returns: Rows of booleans, `true` for a dark module; the matrix is square.
func matrix(for text: String) -> [[Bool]] {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    // "M" restores up to 15 percent of the code; the address is short, so the code stays small and easy to scan.
    filter.correctionLevel = "M"
    guard let image = filter.outputImage else { fail("CoreImage made no QR code") }
    let width = Int(image.extent.width)
    let height = Int(image.extent.height)
    // Draw into an 8-bit grey bitmap, one pixel per module, with no smoothing, then read the pixels back.
    var pixels = [UInt8](repeating: 255, count: width * height)
    let context = CIContext(options: [.useSoftwareRenderer: true])
    let grey = CGColorSpaceCreateDeviceGray()
    context.render(image, toBitmap: &pixels, rowBytes: width, bounds: image.extent, format: .L8, colorSpace: grey)
    let all = (0..<height).map { row in (0..<width).map { column in pixels[row * width + column] < 128 } }
    // CoreImage adds a white border of its own; cut the matrix down to the dark modules so the quiet zone is exactly ours.
    let rows = all.indices.filter { all[$0].contains(true) }
    let columns = (0..<width).filter { column in all.contains { $0[column] } }
    guard let top = rows.first, let bottom = rows.last, let left = columns.first, let right = columns.last else {
        fail("the QR code is empty")
    }
    return (top...bottom).map { row in Array(all[row][left...right]) }
}

/// Writes the matrix as an SVG with one path.
/// - Parameter modules: The module matrix from `matrix(for:)`.
/// - Returns: The SVG text, with a white background and the quiet zone around the code.
func svg(from modules: [[Bool]]) -> String {
    let size = modules.count + quietZone * 2
    var path = ""
    for (y, row) in modules.enumerated() {
        var x = 0
        while x < row.count {
            guard row[x] else { x += 1; continue }
            var end = x
            while end < row.count, row[end] { end += 1 }
            // One run of dark modules in this row: move there, go right, down one, left, close.
            path += "M\(x + quietZone) \(y + quietZone)h\(end - x)v1h-\(end - x)z"
            x = end
        }
    }
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(size) \(size)" shape-rendering="crispEdges" role="img">
    <rect width="\(size)" height="\(size)" fill="#fff"/>
    <path d="\(path)" fill="\(moduleColor)"/>
    </svg>

    """
}

/// Reads the QR code in a picture.
/// - Parameter file: Path of a PNG or JPEG.
/// - Returns: The text the code holds, or nil when no code could be read.
func scan(_ file: String) -> String? {
    guard let image = CIImage(contentsOf: URL(fileURLWithPath: file)) else { return nil }
    let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
    return detector?.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
}

let arguments = CommandLine.arguments
if arguments.count == 4, arguments[1] == "make" {
    let text = arguments[2]
    try svg(from: matrix(for: text)).write(toFile: arguments[3], atomically: true, encoding: .utf8)
    print("wrote \(arguments[3]) for \(text)")
} else if arguments.count == 4, arguments[1] == "check" {
    guard let found = scan(arguments[2]) else { fail("no QR code could be read in \(arguments[2])") }
    guard found == arguments[3] else { fail("the code says \(found), expected \(arguments[3])") }
    print("ok: the code reads \(found)")
} else {
    fail("usage: make <text> <out.svg> | check <picture> <text>")
}

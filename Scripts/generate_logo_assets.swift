// Usage: swift Scripts/generate_logo_assets.swift
// Uses the exact alpha silhouette from logo.png. No redraw, tracing, or AI generation.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let sourceURL = root.appendingPathComponent("logo.png")
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let logo = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("Cannot read logo.png") }
let assets = root.appendingPathComponent("Luma/Assets.xcassets", isDirectory: true)
let iconDirectory = assets.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
let markDirectory = assets.appendingPathComponent("LumaMark.imageset", isDirectory: true)
try FileManager.default.createDirectory(at: markDirectory, withIntermediateDirectories: true)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func context(_ size: Int, transparent: Bool) -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
              space: space, bitmapInfo: (transparent ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
}
func gray(_ value: CGFloat) -> CGColor { CGColor(srgbRed: value, green: value, blue: value, alpha: 1) }
func gradient(_ context: CGContext, top: CGFloat, bottom: CGFloat, size: CGFloat) {
    let gradient = CGGradient(colorsSpace: space, colors: [gray(bottom), gray(top)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size * 0.7, y: size), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
func symbol(size: Int, inset: CGFloat, top: CGFloat, bottom: CGFloat) -> CGImage {
    let canvas = context(size, transparent: true)
    let side = CGFloat(size)
    let available = side - inset * 2
    let scale = available / CGFloat(max(logo.width, logo.height))
    let width = CGFloat(logo.width) * scale, height = CGFloat(logo.height) * scale
    let bounds = CGRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height)
    canvas.interpolationQuality = .high
    canvas.draw(logo, in: bounds)
    canvas.setBlendMode(.sourceIn)
    gradient(canvas, top: top, bottom: bottom, size: side)
    return canvas.makeImage()!
}
func appIcon(dark: Bool, tinted: Bool = false) -> CGImage {
    let canvas = context(1024, transparent: false)
    gradient(canvas, top: dark ? 0.12 : 0.98, bottom: dark ? 0.025 : 0.83, size: 1024)
    let mark = symbol(size: 1024, inset: 84, top: dark ? 0.98 : 0.12, bottom: dark ? (tinted ? 0.92 : 0.78) : 0.24)
    canvas.draw(mark, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    return canvas.makeImage()!
}
func writePNG(_ image: CGImage, to url: URL) throws {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}
func contents(_ images: [[String: Any]], to directory: URL, properties: [String: Any]? = nil) throws {
    var json: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    if let properties { json["properties"] = properties }
    try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("Contents.json"), options: .atomic)
}
func entry(_ filename: String, appearance: String? = nil, icon: Bool = true) -> [String: Any] {
    var item: [String: Any] = ["filename": filename, "idiom": "universal"]
    if icon { item["platform"] = "ios"; item["size"] = "1024x1024" }
    if let appearance { item["appearances"] = [["appearance": "luminosity", "value": appearance]] }
    return item
}

let light = appIcon(dark: false)
let dark = appIcon(dark: true)
let tinted = appIcon(dark: true, tinted: true)
try writePNG(light, to: iconDirectory.appendingPathComponent("AppIcon-Light.png"))
try writePNG(dark, to: iconDirectory.appendingPathComponent("AppIcon-Dark.png"))
try writePNG(tinted, to: iconDirectory.appendingPathComponent("AppIcon-Tinted.png"))
try contents([entry("AppIcon-Light.png"), entry("AppIcon-Dark.png", appearance: "dark"), entry("AppIcon-Tinted.png", appearance: "tinted")], to: iconDirectory)
try? FileManager.default.removeItem(at: iconDirectory.appendingPathComponent("AppIcon.png"))
try writePNG(symbol(size: 512, inset: 0, top: 0.14, bottom: 0.14), to: markDirectory.appendingPathComponent("LumaMark-Light.png"))
try writePNG(symbol(size: 512, inset: 0, top: 0.93, bottom: 0.93), to: markDirectory.appendingPathComponent("LumaMark-Dark.png"))
try contents([entry("LumaMark-Light.png", icon: false), entry("LumaMark-Dark.png", appearance: "dark", icon: false)], to: markDirectory)

// A review image only; exported app icons remain square and have no baked corner mask.
let width = 1260, height = 480
let preview = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
preview.setFillColor(gray(0.18)); preview.fill(CGRect(x: 0, y: 0, width: width, height: height))
for (index, image) in [light, dark, tinted].enumerated() {
    let bounds = CGRect(x: 70 + index * 405, y: 105, width: 310, height: 310)
    preview.saveGState()
    preview.addPath(CGPath(roundedRect: bounds, cornerWidth: 68, cornerHeight: 68, transform: nil))
    preview.clip(); preview.draw(image, in: bounds); preview.restoreGState()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: preview, flipped: false)
    let style = NSMutableParagraphStyle(); style.alignment = .center
    (["Light", "Dark", "Tinted"][index] as NSString).draw(in: CGRect(x: bounds.minX, y: 45, width: 310, height: 34), withAttributes: [.font: NSFont.systemFont(ofSize: 23, weight: .medium), .foregroundColor: NSColor.white, .paragraphStyle: style])
    NSGraphicsContext.restoreGraphicsState()
}
try writePNG(preview.makeImage()!, to: root.appendingPathComponent("Screenshots/app-icons.png"))
print("Created light, dark, tinted, and in-app logo assets from logo.png.")

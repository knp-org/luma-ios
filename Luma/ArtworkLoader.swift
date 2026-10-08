import UIKit
import ImageIO

struct ArtworkSource: Equatable, Sendable {
    let url: URL
    var fallbackFLAC: URL? = nil
}

struct ArtworkTint: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    static let neutral = ArtworkTint(red: 0.45, green: 0.45, blue: 0.45)
}

/// Immutable, decoded artwork; UIKit images are only rendered, never mutated.
final class ArtworkAsset: @unchecked Sendable {
    let image: UIImage
    let tint: ArtworkTint
    init(image: UIImage, tint: ArtworkTint) { self.image = image; self.tint = tint }
}

/// Image decoding and palette extraction run off the main actor and share a bounded cache.
actor ArtworkLoader {
    static let shared = ArtworkLoader()
    private let cache = NSCache<NSURL, ArtworkAsset>()

    init() {
        cache.totalCostLimit = 32 * 1_024 * 1_024
        cache.countLimit = 64
    }

    func load(_ url: URL) -> ArtworkAsset? {
        load(ArtworkSource(url: url))
    }

    func load(_ input: ArtworkSource) -> ArtworkAsset? {
        let url = input.url
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        func thumbnail(_ source: CGImageSource?) -> CGImage? {
            guard let source else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1_024,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        }
        let source = url.pathExtension.lowercased() == "flac" ? nil : CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        var decoded = thumbnail(source)
        if decoded == nil, let data = EmbeddedArtwork.flacPicture(at: input.fallbackFLAC ?? url) {
            decoded = thumbnail(CGImageSourceCreateWithData(data as CFData, nil))
        }
        guard let image = decoded else { return nil }
        let asset = ArtworkAsset(image: UIImage(cgImage: image), tint: Self.dominantTint(in: image))
        cache.setObject(asset, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
        return asset
    }

    nonisolated static func dominantTint(in image: CGImage) -> ArtworkTint {
        let side = 40
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard rendered else { return .neutral }
        struct Bucket {
            var count = 0
            var red = 0.0
            var green = 0.0
            var blue = 0.0
        }
        var buckets = [Bucket](repeating: Bucket(), count: 512)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0.5 else { continue }
            let r = min(1, Double(pixels[index]) / 255 / alpha)
            let g = min(1, Double(pixels[index + 1]) / 255 / alpha)
            let b = min(1, Double(pixels[index + 2]) / 255 / alpha)
            // Ignore near-black borders and white lettering when finding the cover's color.
            guard max(r, g, b) > 0.08, min(r, g, b) < 0.95 else { continue }
            let key = min(7, Int(r * 8)) * 64 + min(7, Int(g * 8)) * 8 + min(7, Int(b * 8))
            buckets[key].count += 1
            buckets[key].red += r; buckets[key].green += g; buckets[key].blue += b
        }
        guard let dominant = buckets.max(by: { $0.count < $1.count }), dominant.count > 0 else { return .neutral }
        let count = Double(dominant.count)
        return ArtworkTint(red: dominant.red / count, green: dominant.green / count, blue: dominant.blue / count)
    }
}

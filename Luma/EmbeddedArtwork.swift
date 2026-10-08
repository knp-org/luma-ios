import Foundation
import ImageIO

/// Reads native FLAC metadata without decoding or loading the audio stream.
enum EmbeddedArtwork {
    static func flacPicture(at url: URL) -> Data? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        do {
            let size = try file.seekToEnd()
            try file.seek(toOffset: 0)
            guard try file.read(upToCount: 4) == Data("fLaC".utf8) else { return nil }
            var fallback: Data?
            var fallbackRank = -1
            for _ in 0..<1_024 {
                let offset = try file.offset()
                guard offset + 4 <= size, offset < 64_000_000,
                      let header = try file.read(upToCount: 4), header.count == 4 else { return fallback }
                let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
                let end = offset + 4 + UInt64(length)
                guard end <= size, end <= 64_000_000 else { return fallback }
                if header[0] & 0x7F == 6 {
                    guard let block = try file.read(upToCount: length), block.count == length else { return fallback }
                    if let picture = picture(in: block), isImage(picture.data) {
                        if picture.type == 3 { return picture.data }
                        let rank = picture.type == 1 || picture.type == 2 ? 0 : 1
                        if rank > fallbackRank { fallback = picture.data; fallbackRank = rank }
                    }
                } else { try file.seek(toOffset: end) }
                if header[0] & 0x80 != 0 { return fallback }
            }
            return fallback
        } catch { return nil }
    }

    static func isImage(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count < 20_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return false }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                             kCGImageSourceThumbnailMaxPixelSize: 32] as CFDictionary) != nil
    }

    private static func picture(in block: Data) -> (type: UInt32, data: Data)? {
        var reader = Reader(data: block)
        guard let type = reader.integer(), let mimeLength = reader.integer(), let mime = reader.bytes(Int(mimeLength)),
              mime != Data("-->".utf8), let descriptionLength = reader.integer(), reader.bytes(Int(descriptionLength)) != nil,
              reader.bytes(16) != nil, let imageLength = reader.integer(), imageLength < 20_000_000,
              let image = reader.bytes(Int(imageLength)) else { return nil }
        return (type, image)
    }

    private struct Reader {
        let data: Data
        var offset = 0
        mutating func bytes(_ count: Int) -> Data? {
            guard count >= 0, count <= data.count - offset else { return nil }
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }
        mutating func integer() -> UInt32? { bytes(4)?.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
    }
}

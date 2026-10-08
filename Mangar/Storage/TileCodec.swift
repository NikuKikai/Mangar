import Compression
import Foundation

enum TileCodec {
    enum CodecError: Error { case invalidTile, compressionFailed, corruptedTile }

    private static let magic = Data([0x4D, 0x47, 0x54, 0x32]) // MGT2
    static let rawSize = CanvasConstants.tileSize * CanvasConstants.tileSize * 4

    static func encode(_ pixels: Data) throws -> Data {
        guard pixels.count == rawSize || pixels.count == rawSize / 4 else { throw CodecError.invalidTile }
        var compressed = Data(count: pixels.count * 2)
        let count = compressed.withUnsafeMutableBytes { destination in
            pixels.withUnsafeBytes { source in
                compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!,
                                          destination.count,
                                          source.bindMemory(to: UInt8.self).baseAddress!,
                                          source.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard count > 0 else { throw CodecError.compressionFailed }
        compressed.count = count
        var result = magic
        var length = UInt32(pixels.count).littleEndian
        var checksum = checksum(pixels).littleEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        withUnsafeBytes(of: &checksum) { result.append(contentsOf: $0) }
        result.append(compressed)
        return result
    }

    static func decode(_ file: Data) throws -> Data {
        guard file.count >= 16, file.prefix(4) == magic else { throw CodecError.corruptedTile }
        let length = file[4..<8].enumerated().reduce(UInt32(0)) {
            $0 | (UInt32($1.element) << ($1.offset * 8))
        }
        let expectedChecksum = file[8..<16].enumerated().reduce(UInt64(0)) {
            $0 | (UInt64($1.element) << ($1.offset * 8))
        }
        guard length == rawSize || length == rawSize / 4 else { throw CodecError.corruptedTile }
        var result = Data(count: Int(length))
        let count = result.withUnsafeMutableBytes { destination in
            file.dropFirst(16).withUnsafeBytes { source in
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!,
                                          destination.count,
                                          source.bindMemory(to: UInt8.self).baseAddress!,
                                          source.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard count == Int(length), checksum(result) == expectedChecksum else {
            throw CodecError.corruptedTile
        }
        return result
    }

    private static func checksum(_ data: Data) -> UInt64 {
        data.reduce(0xcbf29ce484222325) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
    }
}

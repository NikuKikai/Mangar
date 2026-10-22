import Foundation
import CoreGraphics
import Compression
import CryptoKit

/// Derived, replaceable BGRA8 data. The page state file remains authoritative.
nonisolated enum PageRenderRegion: String, Codable, CaseIterable, Sendable {
    case canvas, content
}

nonisolated struct PageRenderImage: Sendable {
    var width: Int
    var height: Int
    var pixels: Data
}

nonisolated enum PageRenderCache {
    static let maximumDimension = 4096
    private static let version = 1
    private struct Header: Codable {
        var version: Int
        var revision: String
        var region: PageRenderRegion
        var bounds: CGRect
        var width: Int
        var height: Int
        var checksum: String
    }
    enum CacheError: Error { case invalidData }

    static func revision(root: URL, pageID: UUID) throws -> String {
        digest(try Data(contentsOf: directory(root:root,pageID:pageID).appendingPathComponent("state.json")))
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    }
    private static func directory(root: URL, pageID: UUID) -> URL {
        root.appendingPathComponent("pages").appendingPathComponent(pageID.uuidString)
    }
    private static func file(root: URL,pageID:UUID,region:PageRenderRegion) -> URL {
        directory(root:root,pageID:pageID).appendingPathComponent("previews").appendingPathComponent(region.rawValue+".mgpreview")
    }

    /// One atomic file contains both identity and LZFSE pixels, so an interrupted
    /// update never pairs a new header with old image data.
    static func write(_ image: PageRenderImage, bounds: CGRect, region: PageRenderRegion,
                      revision: String, root: URL,pageID: UUID) throws {
        try Task.checkCancellation()
        guard image.width>0,image.height>0,image.width<=maximumDimension,image.height<=maximumDimension,
              image.pixels.count == image.width*image.height*4 else { throw CacheError.invalidData }
        var compressed=Data(count:image.pixels.count+max(1024,image.pixels.count/16))
        let count=compressed.withUnsafeMutableBytes { destination in
            image.pixels.withUnsafeBytes { source in
                compression_encode_buffer(destination.bindMemory(to:UInt8.self).baseAddress!,destination.count,
                    source.bindMemory(to:UInt8.self).baseAddress!,source.count,nil,COMPRESSION_LZFSE)
            }
        }
        guard count>0 else { throw CacheError.invalidData };compressed.count=count
        let header=Header(version:version,revision:revision,region:region,bounds:bounds,
            width:image.width,height:image.height,checksum:digest(image.pixels))
        let metadata=try JSONEncoder().encode(header)
        var length=UInt32(metadata.count).littleEndian
        var data=Data([0x4d,0x47,0x50,0x31]) // MGP1
        withUnsafeBytes(of:&length) { data.append(contentsOf:$0) }
        data.append(metadata);data.append(compressed)
        try Task.checkCancellation()
        guard try self.revision(root:root,pageID:pageID) == revision else { return }
        let target=file(root:root,pageID:pageID,region:region)
        try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
        try data.write(to:target,options:.atomic)
    }

    /// Missing, stale or corrupt cache is always a miss, never a document error.
    static func read(root: URL,pageID:UUID,region:PageRenderRegion,
                     revision:String,bounds:CGRect) -> PageRenderImage? {
        do {
            let data=try Data(contentsOf:file(root:root,pageID:pageID,region:region),options:.mappedIfSafe)
            guard data.count>8,data.prefix(4) == Data([0x4d,0x47,0x50,0x31]) else { return nil }
            let length=data[4..<8].enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element)<<($1.offset*8)) }
            guard length>0,length<65536,Int(length)+8<data.count else { return nil }
            let end=Int(length)+8
            let header=try JSONDecoder().decode(Header.self,from:Data(data[8..<end]))
            guard header.version == version,header.revision == revision,header.region == region,header.bounds == bounds,
                  header.width>0,header.height>0,header.width<=maximumDimension,header.height<=maximumDimension else { return nil }
            var pixels=Data(count:header.width*header.height*4)
            let count=pixels.withUnsafeMutableBytes { destination in
                data[end...].withUnsafeBytes { source in
                    compression_decode_buffer(destination.bindMemory(to:UInt8.self).baseAddress!,destination.count,
                        source.bindMemory(to:UInt8.self).baseAddress!,source.count,nil,COMPRESSION_LZFSE)
                }
            }
            guard count == pixels.count,digest(pixels) == header.checksum else { return nil }
            return PageRenderImage(width:header.width,height:header.height,pixels:pixels)
        } catch { return nil }
    }
}

import AppKit
import Darwin

/// Private, bounded protocol over an inherited anonymous local socket. Pixels
/// are sent separately so JSON never expands or base64-copies a screenshot.
struct OCRWorkerRequest: Codable, Sendable {
    enum Mode: String, Codable, Sendable { case text, word, verify }
    let mode: Mode
    let width: Int
    let height: Int
    let maximumCount: Int
    let region: CGRect?
    let point: CGPoint?

    var pixelCount: Int {
        get throws {
            guard (1...4096).contains(width), (1...4096).contains(height),
                  (1...65_536).contains(maximumCount) else { throw HoverLookupError.captureFailed }
            if mode == .word {
                guard let region, let point, HoverWords.valid(region),
                      point.x.isFinite, point.y.isFinite, region.contains(point) else {
                    throw HoverLookupError.captureFailed
                }
            }
            return width * height * 4
        }
    }

    func pixels(from image: CGImage) throws -> Data {
        let count = try pixelCount
        guard image.width == width, image.height == height else { throw HoverLookupError.captureFailed }
        var pixels = Data(count: count)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: Self.bitmapInfo.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw HoverLookupError.captureFailed }
        return pixels
    }

    func image(from pixels: Data) throws -> CGImage {
        guard pixels.count == (try pixelCount), let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: Self.bitmapInfo,
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw HoverLookupError.captureFailed
        }
        return image
    }

    private static let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
}

struct OCRWorkerResponse: Codable, Sendable {
    enum Status: String, Codable, Sendable { case success, noText, tooLong, failure, unavailable }
    let status: Status
    var text: String?
    var anchor: CGRect?
    var failure: OCRFailure?
}

enum OCRWorkerChannel {
    static let responseLimit = 1024 * 1024
    static let requestLimit = 4096

    static func configure(_ descriptor: Int32) throws {
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                        socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw HoverLookupError.recognitionFailed }
    }

    static func sendMessage<Value: Encodable>(_ value: Value, to descriptor: Int32, limit: Int) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= limit else { throw HoverLookupError.recognitionFailed }
        var size = UInt32(data.count).bigEndian
        try withUnsafeBytes(of: &size) { try send($0, to: descriptor) }
        try data.withUnsafeBytes { try send($0, to: descriptor) }
    }

    static func receiveMessage<Value: Decodable>(_ type: Value.Type, from descriptor: Int32, limit: Int) throws -> Value {
        let prefix = try receive(count: 4, from: descriptor)
        let size = prefix.reduce(0) { ($0 << 8) | Int($1) }
        guard size > 0, size <= limit else { throw HoverLookupError.recognitionFailed }
        return try JSONDecoder().decode(type, from: receive(count: size, from: descriptor))
    }

    static func send(_ bytes: UnsafeRawBufferPointer, to descriptor: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            let written = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { throw HoverLookupError.recognitionFailed }
            offset += written
        }
    }

    static func receive(count: Int, from descriptor: Int32) throws -> Data {
        // Both caller sites validate the length before allocating it.
        guard count > 0, count <= 4096 * 4096 * 4 else { throw HoverLookupError.recognitionFailed }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let read = recv(descriptor, bytes.baseAddress!.advanced(by: offset), count - offset, 0)
                if read < 0 && errno == EINTR { continue }
                guard read > 0 else { throw HoverLookupError.recognitionFailed }
                offset += read
            }
        }
        return data
    }
}

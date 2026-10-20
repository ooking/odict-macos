import Foundation
import zlib

enum LocalDictionaryError: LocalizedError {
    case invalid(String), unsupported(String), missingResource
    var errorDescription: String? {
        switch self {
        case .invalid(let detail): return "词典文件无法读取：\(detail)"
        case .unsupported(let detail): return "暂不支持此词典：\(detail)"
        case .missingResource: return "词典资源不存在。"
        }
    }
}

/// Bounds checked, endian independent input. Never maps an entire dictionary.
struct MDXCursor {
    let bytes: [UInt8]
    var position = 0
    init(_ data: Data) { bytes = Array(data) }
    var remaining: Int { bytes.count - position }
    mutating func number(_ width: Int) throws -> UInt64 {
        guard width > 0, width <= 8, remaining >= width else { throw LocalDictionaryError.invalid("整数越界") }
        var value: UInt64 = 0
        for _ in 0..<width { value = (value << 8) | UInt64(bytes[position]); position += 1 }
        return value
    }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw LocalDictionaryError.invalid("数据越界") }
        defer { position += count }
        return Data(bytes[position..<(position + count)])
    }
    mutating func terminated(unit: Int) throws -> Data {
        let start = position
        while remaining >= unit {
            if bytes[position..<(position + unit)].allSatisfy({ $0 == 0 }) {
                let value = Data(bytes[start..<position]); position += unit; return value
            }
            position += unit
        }
        throw LocalDictionaryError.invalid("缺少字符串结束符")
    }
}

enum MDXCompression {
    static let limit = 32 * 1024 * 1024
    static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { buffer in
            UInt32(adler32(adler32(0, nil, 0), buffer.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)))
        }
    }
    static func decode(_ data: Data, expected: Int) throws -> Data {
        guard data.count >= 8, expected > 0, expected <= limit else { throw LocalDictionaryError.invalid("数据块大小异常") }
        let tag = Array(data.prefix(4))
        var cursor = MDXCursor(Data(data.dropFirst(4)))
        let checksum = UInt32(try cursor.number(4))
        let payload = Data(data.dropFirst(8))
        let result: Data
        switch tag {
        case [0, 0, 0, 0]: result = payload
        case [2, 0, 0, 0]:
            var output = Data(count: expected)
            var length = uLongf(expected)
            let status = output.withUnsafeMutableBytes { destination in
                payload.withUnsafeBytes { source in
                    uncompress(destination.bindMemory(to: Bytef.self).baseAddress!, &length,
                               source.bindMemory(to: Bytef.self).baseAddress!, uLong(payload.count))
                }
            }
            guard status == Z_OK, length == expected else { throw LocalDictionaryError.invalid("zlib 解压失败") }
            result = output
        case [1, 0, 0, 0]: throw LocalDictionaryError.unsupported("LZO 压缩；当前读取器支持 zlib 和未压缩数据块")
        default: throw LocalDictionaryError.unsupported("未知压缩方式")
        }
        guard result.count == expected else { throw LocalDictionaryError.invalid("数据块长度不匹配") }
        guard Self.checksum(result) == checksum else { throw LocalDictionaryError.invalid("数据块校验失败") }
        return result
    }

    static func decryptIndex(_ data: Data) throws -> Data {
        guard data.count >= 8 else { throw LocalDictionaryError.invalid("加密索引不完整") }
        let key = RIPEMD128.digest(Data(data[4..<8]) + Data([0x95, 0x36, 0, 0]))
        var bytes = Array(data)
        var previous: UInt8 = 0x36
        for i in 8..<bytes.count {
            let original = bytes[i]
            bytes[i] = ((original >> 4) | (original << 4)) ^ previous ^ UInt8(truncatingIfNeeded: i - 8) ^ key[(i - 8) % 16]
            previous = original
        }
        return Data(bytes)
    }
}

/// RIPEMD-128 as specified by its four parallel rounds. Used only by MDX's index codec.
enum RIPEMD128 {
    private static let left = [
        0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,
        7,4,13,1,10,6,15,3,12,0,9,5,2,14,11,8,
        3,10,14,4,9,15,8,1,2,7,0,6,13,11,5,12,
        1,9,11,10,0,8,12,4,13,3,7,15,14,5,6,2]
    private static let right = [
        5,14,7,0,9,2,11,4,13,6,15,8,1,10,3,12,
        6,11,3,7,0,13,5,10,14,15,8,12,4,9,1,2,
        15,5,1,3,7,14,6,9,11,8,12,2,10,0,4,13,
        8,6,4,1,3,11,15,0,5,12,2,13,9,7,10,14]
    private static let ls = [
        11,14,15,12,5,8,7,9,11,13,14,15,6,7,9,8,
        7,6,8,13,11,9,7,15,7,12,15,9,11,7,13,12,
        11,13,6,7,14,9,13,15,14,8,13,6,5,12,7,5,
        11,12,14,15,14,15,9,8,9,14,5,6,8,6,5,12]
    private static let rs = [
        8,9,9,11,13,15,15,5,7,7,8,11,14,14,12,6,
        9,13,15,7,12,8,9,11,7,7,12,7,6,15,13,11,
        9,7,15,11,8,6,6,14,12,13,5,14,13,13,7,5,
        15,5,8,11,14,14,6,14,6,9,12,9,12,5,15,8]
    private static func f(_ round: Int, _ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        switch round {
        case 0: return x ^ y ^ z
        case 1: return (x & y) | (~x & z)
        case 2: return (x | ~y) ^ z
        default: return (x & z) | (y & ~z)
        }
    }
    static func digest(_ input: Data) -> [UInt8] {
        var bytes = Array(input)
        let bits = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: bits >> (8 * i))) }
        var h: [UInt32] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476]
        let lk: [UInt32] = [0, 0x5a827999, 0x6ed9eba1, 0x8f1bbcdc]
        let rk: [UInt32] = [0x50a28be6, 0x5c4dd124, 0x6d703ef3, 0]
        for base in stride(from: 0, to: bytes.count, by: 64) {
            let words: [UInt32] = (0..<16).map { i in
                let p = base + i * 4
                return UInt32(bytes[p]) | UInt32(bytes[p+1]) << 8 | UInt32(bytes[p+2]) << 16 | UInt32(bytes[p+3]) << 24
            }
            var a = h[0], b = h[1], c = h[2], d = h[3]
            var aa = a, bb = b, cc = c, dd = d
            for i in 0..<64 {
                let round = i / 16
                let t = a &+ f(round, b, c, d) &+ words[left[i]] &+ lk[round]
                let rotated = (t << ls[i]) | (t >> (32 - ls[i]))
                a = d; d = c; c = b; b = rotated
                let tt = aa &+ f(3 - round, bb, cc, dd) &+ words[right[i]] &+ rk[round]
                let rr = (tt << rs[i]) | (tt >> (32 - rs[i]))
                aa = dd; dd = cc; cc = bb; bb = rr
            }
            let t = h[1] &+ c &+ dd
            h[1] = h[2] &+ d &+ aa
            h[2] = h[3] &+ a &+ bb
            h[3] = h[0] &+ b &+ cc
            h[0] = t
        }
        return h.flatMap { value in (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
    }
}

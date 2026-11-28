import Foundation

/// 一則訊息可能比單一藍牙封包大。每個封包第一個位元組是旗標：bit0 表示第一段，bit1 表示最後一段。
public enum Framing {
    public static let flagStart: UInt8 = 1
    public static let flagEnd: UInt8 = 2

    /// 把訊息切成每段不超過 `maxChunk` 位元組（含旗標）的封包。
    public static func split(_ message: Data, maxChunk: Int) -> [Data] {
        let bytes = [UInt8](message)
        let size = max(1, maxChunk - 1)
        if bytes.isEmpty { return [Data([flagStart | flagEnd])] }
        var out: [Data] = []
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + size, bytes.count)
            var flags: UInt8 = 0
            if offset == 0 { flags |= flagStart }
            if end == bytes.count { flags |= flagEnd }
            out.append(Data([flags] + bytes[offset..<end]))
            offset = end
        }
        return out
    }
}

/// 把依序收到的封包組回完整訊息。沒有從第一段開始的封包會被丟棄。
public struct Reassembler {
    private var buffer: [UInt8] = []
    private var active = false

    public init() {}

    public mutating func feed(_ chunk: Data) -> Data? {
        let bytes = [UInt8](chunk)
        guard let flags = bytes.first else { return nil }
        if flags & Framing.flagStart != 0 {
            buffer = []
            active = true
        }
        guard active else { return nil }
        buffer.append(contentsOf: bytes.dropFirst())
        if flags & Framing.flagEnd != 0 {
            active = false
            let message = Data(buffer)
            buffer = []
            return message
        }
        return nil
    }
}

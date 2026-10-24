import Foundation

// Codable mirror of schema/miner-status.schema.json (schemaVersion 1).
//
// Decoding rules shared by every object below:
// - Every key is required. A missing key fails decoding; an explicit JSON null decodes to
//   nil (shown as 無資料). Synthesized Codable would use decodeIfPresent and silently accept
//   a missing key, so all types decode by hand. The one exception is the optional earnings
//   extension (`feed.market`, `machine.earnings`), sent only to clients that ask for it.
// - Keys outside the whitelist fail decoding instead of being ignored.
// - The string "unknown" is kept distinct from null via `Reported`.
// - Encoding writes explicit nulls so a round trip stays schema-valid.
//
// Receive time and monotonic time are client-side and deliberately absent here.

// MARK: - Feed

public struct MinerStatusFeed: Codable, Hashable, Sendable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let dataOrigin: DataOrigin
    /// Non-empty when `dataOrigin == .demo`, nil when `.live`.
    public let demoNotice: String?
    /// When the publisher wrote/served the document. Never makes any `observedAt` newer.
    public let publishedAt: Timestamp?
    public let machines: [MachineStatus]
    /// Optional extension: nil when absent or null.
    public let market: MarketReport?

    public var isDemo: Bool { dataOrigin == .demo }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, dataOrigin, demoNotice, publishedAt, machines, market
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)

        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: c,
                debugDescription: "unsupported schemaVersion \(schemaVersion)")
        }

        dataOrigin = try c.decode(DataOrigin.self, forKey: .dataOrigin)
        demoNotice = try c.decodeNullable(String.self, forKey: .demoNotice)
        switch dataOrigin {
        case .demo:
            guard let notice = demoNotice, !notice.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .demoNotice, in: c,
                    debugDescription: "demo data requires a non-empty demoNotice")
            }
        case .live:
            guard demoNotice == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .demoNotice, in: c,
                    debugDescription: "live data must have a null demoNotice")
            }
        }

        publishedAt = try c.decodeNullable(Timestamp.self, forKey: .publishedAt)
        machines = try c.decode([MachineStatus].self, forKey: .machines)
        market = c.contains(.market) ? try c.decodeNullable(MarketReport.self, forKey: .market) : nil

        // Stricter than the schema: duplicate ids would let samples from different
        // machines be compared against each other.
        var seen = Set<String>()
        for machine in machines where !seen.insert(machine.machineId).inserted {
            throw DecodingError.dataCorruptedError(
                forKey: .machines, in: c,
                debugDescription: "duplicate machineId \(machine.machineId)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(dataOrigin, forKey: .dataOrigin)
        try c.encode(demoNotice, forKey: .demoNotice)
        try c.encode(publishedAt, forKey: .publishedAt)
        try c.encode(machines, forKey: .machines)
        try c.encodeIfPresent(market, forKey: .market)
    }
}

public enum DataOrigin: String, Codable, Hashable, Sendable {
    case demo
    case live
}

// MARK: - Machine

public struct MachineStatus: Codable, Hashable, Sendable {
    public let machineId: String
    public let displayName: String
    public let worker: String?
    public let sourceStatus: SourceStatus
    public let sourceCheckedAt: Timestamp?
    /// Opaque id of one mining run. Counters, sequences and stop results compare only within it.
    public let sessionId: String?
    /// Strictly increasing per session at the source; same or lower means replay/stale.
    public let sampleSequence: Int?
    /// Data time on the source clock; bounded by client receive time, never trusted as absolute.
    public let observedAt: Timestamp?
    /// Operator intent, not an observation. Never inferred from `minerRunning`.
    public let expectedRunning: Reported<Bool>
    public let minerRunning: MinerRunningReport
    public let hashrate: HashrateReport
    /// nil when no GPU data.
    public let gpus: [GPUStatus]?
    public let shares: SharesReport
    public let stop: StopReport
    /// Optional extension: nil when absent or null.
    public let earnings: EarningsReport?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case machineId, displayName, worker, sourceStatus, sourceCheckedAt, sessionId,
             sampleSequence, observedAt, expectedRunning, minerRunning, hashrate, gpus,
             shares, stop, earnings
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)

        machineId = try c.decode(String.self, forKey: .machineId)
        let idIsValid = !machineId.isEmpty && machineId.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar))
        }
        guard idIsValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .machineId, in: c, debugDescription: "machineId must match ^[A-Za-z0-9._-]+$")
        }

        displayName = try c.decode(String.self, forKey: .displayName)
        guard !displayName.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .displayName, in: c, debugDescription: "displayName must not be empty")
        }

        worker = try c.decodeNullable(String.self, forKey: .worker)
        sourceStatus = try c.decode(SourceStatus.self, forKey: .sourceStatus)
        sourceCheckedAt = try c.decodeNullable(Timestamp.self, forKey: .sourceCheckedAt)
        sessionId = try c.decodeSessionID(forKey: .sessionId)
        sampleSequence = try c.decodeNonNegativeInt(forKey: .sampleSequence)
        observedAt = try c.decodeNullable(Timestamp.self, forKey: .observedAt)
        expectedRunning = try c.decodeReported(Bool.self, forKey: .expectedRunning)
        minerRunning = try c.decode(MinerRunningReport.self, forKey: .minerRunning)
        hashrate = try c.decode(HashrateReport.self, forKey: .hashrate)
        gpus = try c.decodeNullable([GPUStatus].self, forKey: .gpus)
        shares = try c.decode(SharesReport.self, forKey: .shares)
        stop = try c.decode(StopReport.self, forKey: .stop)
        earnings = c.contains(.earnings) ? try c.decodeNullable(EarningsReport.self, forKey: .earnings) : nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(machineId, forKey: .machineId)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(worker, forKey: .worker)
        try c.encode(sourceStatus, forKey: .sourceStatus)
        try c.encode(sourceCheckedAt, forKey: .sourceCheckedAt)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(sampleSequence, forKey: .sampleSequence)
        try c.encode(observedAt, forKey: .observedAt)
        try c.encode(expectedRunning, forKey: .expectedRunning)
        try c.encode(minerRunning, forKey: .minerRunning)
        try c.encode(hashrate, forKey: .hashrate)
        try c.encode(gpus, forKey: .gpus)
        try c.encode(shares, forKey: .shares)
        try c.encode(stop, forKey: .stop)
        try c.encodeIfPresent(earnings, forKey: .earnings)
    }
}

// MARK: - Earnings extension

/// Prices for converting estimated earnings. USD prices; `usdTwd` is TWD per USD.
public struct MarketReport: Codable, Hashable, Sendable {
    public let coin: String
    public let coinUsd: Double?
    public let btcUsd: Double?
    public let usdTwd: Double?
    public let observedAt: Timestamp?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case coin, coinUsd, btcUsd, usdTwd, observedAt
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        coin = try c.decode(String.self, forKey: .coin)
        let coinIsValid = (2 ... 10).contains(coin.count) && coin.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.uppercaseLetters.contains($0) || CharacterSet.decimalDigits.contains($0))
        }
        guard coinIsValid else {
            throw DecodingError.dataCorruptedError(forKey: .coin, in: c, debugDescription: "coin must match ^[A-Z0-9]{2,10}$")
        }
        coinUsd = try c.decodeNumber(forKey: .coinUsd, minimum: 0)
        btcUsd = try c.decodeNumber(forKey: .btcUsd, minimum: 0, exclusiveMinimum: true)
        usdTwd = try c.decodeNumber(forKey: .usdTwd, minimum: 0, exclusiveMinimum: true)
        observedAt = try c.decodeNullable(Timestamp.self, forKey: .observedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(coin, forKey: .coin)
        try c.encode(coinUsd, forKey: .coinUsd)
        try c.encode(btcUsd, forKey: .btcUsd)
        try c.encode(usdTwd, forKey: .usdTwd)
        try c.encode(observedAt, forKey: .observedAt)
    }
}

/// Pool-side estimate for one machine: coin per day at the pool's recent average hashrate,
/// after the pool fee. An estimate, not the credited amount.
public struct EarningsReport: Codable, Hashable, Sendable {
    public let coinPerDay: Double?
    /// H/s.
    public let poolHashrate: Double?
    /// Publisher's default; the app lets the user override it.
    public let electricityBilled: Bool?
    public let observedAt: Timestamp?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case coinPerDay, poolHashrate, electricityBilled, observedAt
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        coinPerDay = try c.decodeNumber(forKey: .coinPerDay, minimum: 0)
        poolHashrate = try c.decodeNumber(forKey: .poolHashrate, minimum: 0)
        electricityBilled = try c.decodeNullable(Bool.self, forKey: .electricityBilled)
        observedAt = try c.decodeNullable(Timestamp.self, forKey: .observedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(coinPerDay, forKey: .coinPerDay)
        try c.encode(poolHashrate, forKey: .poolHashrate)
        try c.encode(electricityBilled, forKey: .electricityBilled)
        try c.encode(observedAt, forKey: .observedAt)
    }
}

/// Publisher's last attempt to read the machine. Anything but `.ok` makes the sample historical at best.
public enum SourceStatus: String, Codable, Hashable, Sendable {
    case ok
    case unreachable
    case error
    case noDataYet
}

// MARK: - Miner process

public enum MinerProcessState: String, Codable, Hashable, Sendable {
    case running
    case stopped
}

public struct MinerRunningReport: Codable, Hashable, Sendable {
    /// Observed miner child process. A live guard/source script alone is not `.running`.
    public let state: Reported<MinerProcessState>
    public let observedAt: Timestamp?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case state, observedAt
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeReported(MinerProcessState.self, forKey: .state)
        observedAt = try c.decodeNullable(Timestamp.self, forKey: .observedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state)
        try c.encode(observedAt, forKey: .observedAt)
    }
}

// MARK: - Hashrate

public enum HashrateUnit: String, Codable, Hashable, Sendable, CaseIterable {
    case hashesPerSecond = "H/s"
    case kilohashesPerSecond = "kH/s"
    case megahashesPerSecond = "MH/s"
    case gigahashesPerSecond = "GH/s"
    case terahashesPerSecond = "TH/s"

    public var hashesPerSecondMultiplier: Double {
        switch self {
        case .hashesPerSecond: return 1
        case .kilohashesPerSecond: return 1e3
        case .megahashesPerSecond: return 1e6
        case .gigahashesPerSecond: return 1e9
        case .terahashesPerSecond: return 1e12
        }
    }
}

public struct HashrateReport: Codable, Hashable, Sendable {
    /// May be reused from an old log line; freshness comes from `observedAt`, and a positive
    /// value alone is never mining evidence.
    public let value: Double?
    public let unit: HashrateUnit?
    public let observedAt: Timestamp?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case value, unit, observedAt
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = try c.decodeNumber(forKey: .value, minimum: 0)
        unit = try c.decodeNullable(HashrateUnit.self, forKey: .unit)
        observedAt = try c.decodeNullable(Timestamp.self, forKey: .observedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(value, forKey: .value)
        try c.encode(unit, forKey: .unit)
        try c.encode(observedAt, forKey: .observedAt)
    }
}

// MARK: - GPU

public struct GPUStatus: Codable, Hashable, Sendable {
    public let index: Int
    public let temperatureC: Double?
    public let fanPercent: Double?
    public let powerW: Double?
    public let observedAt: Timestamp?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case index, temperatureC, fanPercent, powerW, observedAt
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        guard index >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .index, in: c, debugDescription: "must be >= 0")
        }
        temperatureC = try c.decodeNumber(forKey: .temperatureC, minimum: -40, maximum: 150)
        fanPercent = try c.decodeNumber(forKey: .fanPercent, minimum: 0, maximum: 100)
        powerW = try c.decodeNumber(forKey: .powerW, minimum: 0)
        observedAt = try c.decodeNullable(Timestamp.self, forKey: .observedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(index, forKey: .index)
        try c.encode(temperatureC, forKey: .temperatureC)
        try c.encode(fanPercent, forKey: .fanPercent)
        try c.encode(powerW, forKey: .powerW)
        try c.encode(observedAt, forKey: .observedAt)
    }
}

// MARK: - Shares

public struct SharesReport: Codable, Hashable, Sendable {
    /// Cumulative within the session; only an increase within the same session is new evidence.
    public let accepted: Int?
    /// nil when not recorded; never defaulted to 0.
    public let stale: Int?
    /// nil when not recorded; never defaulted to 0.
    public let rejected: Int?
    public let observedAt: Timestamp?
    /// Source time of the latest accepted share in this session; nil until calibrated.
    public let lastAcceptedAt: Timestamp?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case accepted, stale, rejected, observedAt, lastAcceptedAt
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accepted = try c.decodeNonNegativeInt(forKey: .accepted)
        stale = try c.decodeNonNegativeInt(forKey: .stale)
        rejected = try c.decodeNonNegativeInt(forKey: .rejected)
        observedAt = try c.decodeNullable(Timestamp.self, forKey: .observedAt)
        lastAcceptedAt = try c.decodeNullable(Timestamp.self, forKey: .lastAcceptedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accepted, forKey: .accepted)
        try c.encode(stale, forKey: .stale)
        try c.encode(rejected, forKey: .rejected)
        try c.encode(observedAt, forKey: .observedAt)
        try c.encode(lastAcceptedAt, forKey: .lastAcceptedAt)
    }
}

// MARK: - Stop

public enum StopReason: String, Codable, Hashable, Sendable {
    case userRequested
    case protectionTriggered
    case abnormalExit
}

public struct StopReport: Codable, Hashable, Sendable {
    /// `.noData` = no stop recorded for this session. Staleness/disconnect is never a stop reason.
    public let reason: Reported<StopReason>
    /// Applies only when equal to the machine's `sessionId`.
    public let sessionId: String?
    public let observedAt: Timestamp?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case reason, sessionId, observedAt
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reason = try c.decodeReported(StopReason.self, forKey: .reason)
        sessionId = try c.decodeSessionID(forKey: .sessionId)
        observedAt = try c.decodeNullable(Timestamp.self, forKey: .observedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(reason, forKey: .reason)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(observedAt, forKey: .observedAt)
    }
}

// MARK: - Reported (value / "unknown" / null)

/// Keeps JSON null (`.noData`, 無資料) distinct from the string "unknown" (`.unknown`, 未知).
public enum Reported<Value> {
    case value(Value)
    case unknown
    case noData

    static var unknownToken: String { "unknown" }

    /// The reported value, or nil for both "unknown" and null. Named differently from the
    /// `value` case to avoid a member-name clash.
    public var knownValue: Value? {
        if case .value(let v) = self { return v }
        return nil
    }
}

extension Reported: Equatable where Value: Equatable {}
extension Reported: Hashable where Value: Hashable {}
extension Reported: Sendable where Value: Sendable {}

extension Reported: Decodable where Value: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .noData
        } else if let text = try? c.decode(String.self), text == Self.unknownToken {
            self = .unknown
        } else {
            self = .value(try c.decode(Value.self))
        }
    }
}

extension Reported: Encodable where Value: Encodable {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .value(let v): try c.encode(v)
        case .unknown: try c.encode(Self.unknownToken)
        case .noData: try c.encodeNil()
        }
    }
}

// MARK: - Timestamp

/// RFC 3339 date-time with an explicit offset (`Z` or `±hh:mm`), parsed without locale or
/// calendar state. Times lacking a date or offset are rejected rather than guessed.
/// Equality and ordering use the instant; the original text is kept for display/encoding.
public struct Timestamp: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let date: Date
    public let rfc3339: String

    public init?(rfc3339 text: String) {
        guard let date = Self.parse(text) else { return nil }
        self.date = date
        self.rfc3339 = text
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let text = try c.decode(String.self)
        guard let parsed = Timestamp(rfc3339: text) else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "expected RFC 3339 date-time with explicit offset")
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rfc3339)
    }

    public static func == (lhs: Timestamp, rhs: Timestamp) -> Bool { lhs.date == rhs.date }
    public static func < (lhs: Timestamp, rhs: Timestamp) -> Bool { lhs.date < rhs.date }
    public func hash(into hasher: inout Hasher) { hasher.combine(date) }
    public var description: String { rfc3339 }

    /// Accepts exactly `YYYY-MM-DDTHH:MM:SS(.f{1,9})?(Z|±HH:MM)`; leap second 60 is rejected.
    static func parse(_ text: String) -> Date? {
        let bytes = Array(text.utf8)
        var i = 0

        func digits(_ count: Int) -> Int? {
            guard i + count <= bytes.count else { return nil }
            var value = 0
            for byte in bytes[i ..< i + count] {
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            i += count
            return value
        }
        func expect(_ char: Unicode.Scalar) -> Bool {
            guard i < bytes.count, bytes[i] == UInt8(ascii: char) else { return false }
            i += 1
            return true
        }

        guard let year = digits(4), expect("-"),
              let month = digits(2), expect("-"),
              let day = digits(2), expect("T"),
              let hour = digits(2), expect(":"),
              let minute = digits(2), expect(":"),
              let second = digits(2)
        else { return nil }

        var fraction = 0.0
        if expect(".") {
            var scale = 1.0
            var count = 0
            while i < bytes.count, bytes[i] >= UInt8(ascii: "0"), bytes[i] <= UInt8(ascii: "9") {
                scale /= 10
                fraction += Double(bytes[i] - UInt8(ascii: "0")) * scale
                count += 1
                i += 1
            }
            guard (1 ... 9).contains(count) else { return nil }
        }

        var offsetSeconds = 0
        if expect("Z") {
            offsetSeconds = 0
        } else {
            let sign: Int
            if expect("+") { sign = 1 } else if expect("-") { sign = -1 } else { return nil }
            guard let offsetHour = digits(2), expect(":"), let offsetMinute = digits(2),
                  offsetHour <= 23, offsetMinute <= 59
            else { return nil }
            offsetSeconds = sign * (offsetHour * 3600 + offsetMinute * 60)
        }
        guard i == bytes.count else { return nil }

        guard (1 ... 12).contains(month),
              (1 ... daysInMonth(year: year, month: month)).contains(day),
              hour <= 23, minute <= 59, second <= 59
        else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar (H. Hinnant's algorithm).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let shiftedMonth = (month + 9) % 12
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}

// MARK: - Decoding helpers

struct AnyCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Whitelist enforcement: any key not declared in `allowed` fails decoding.
func rejectUnknownKeys<K: CodingKey & CaseIterable>(_ decoder: Decoder, allowed: K.Type) throws {
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    let allowedNames = Set(K.allCases.map(\.stringValue))
    let extra = container.allKeys.map(\.stringValue).filter { !allowedNames.contains($0) }.sorted()
    guard extra.isEmpty else {
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "non-whitelisted keys: \(extra.joined(separator: ", "))"))
    }
}

extension KeyedDecodingContainer {
    /// Key must be present; JSON null decodes to nil.
    func decodeNullable<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        try decode(T?.self, forKey: key)
    }

    /// Key must be present; null → `.noData`, "unknown" → `.unknown`.
    func decodeReported<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> Reported<T> {
        try decodeNullable(Reported<T>.self, forKey: key) ?? .noData
    }

    func decodeNonNegativeInt(forKey key: Key) throws -> Int? {
        guard let value = try decodeNullable(Int.self, forKey: key) else { return nil }
        guard value >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "must be >= 0")
        }
        return value
    }

    func decodeNumber(forKey key: Key, minimum: Double, maximum: Double? = nil, exclusiveMinimum: Bool = false) throws -> Double? {
        guard let value = try decodeNullable(Double.self, forKey: key) else { return nil }
        let aboveMinimum = exclusiveMinimum ? value > minimum : value >= minimum
        guard value.isFinite, aboveMinimum, maximum.map({ value <= $0 }) ?? true else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "number out of range")
        }
        return value
    }

    func decodeSessionID(forKey key: Key) throws -> String? {
        guard let value = try decodeNullable(String.self, forKey: key) else { return nil }
        guard (1 ... 128).contains(value.unicodeScalars.count) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self, debugDescription: "sessionId length must be 1...128")
        }
        return value
    }
}

import Foundation

/// VLC invokes these synchronous callbacks on its input worker, never the UI thread.
/// Only one bounded chunk is retained; seek/close wake a pending read immediately.
final class SMBInputStream: InputStream, @unchecked Sendable {
    typealias Load = @Sendable (Range<Int64>) async throws -> Data
    private let load: Load
    private let size: Int64
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var state: Stream.Status = .notOpen
    private var failure: Error?
    private var offset: Int64 = 0
    private var bufferStart: Int64 = 0
    private var buffered = Data()
    private var pending: StreamRead?

    init(size: Int64, timeout: TimeInterval = 30, load: @escaping Load) {
        self.size = max(0, size)
        self.timeout = timeout
        self.load = load
        super.init(data: Data())
    }

    override var streamStatus: Stream.Status { locked { state } }
    override var streamError: Error? { locked { failure } }
    override var hasBytesAvailable: Bool { locked { state == .open && offset < size } }
    override func open() { locked { if state == .notOpen { state = .open } } }
    override func close() {
        let read = locked { () -> StreamRead? in
            state = .closed
            buffered.removeAll()
            defer { pending = nil }
            return pending
        }
        read?.cancel()
    }
    override func property(forKey key: Stream.PropertyKey) -> Any? {
        key == .fileCurrentOffsetKey ? locked { NSNumber(value: offset) } : nil
    }
    override func setProperty(_ property: Any?, forKey key: Stream.PropertyKey) -> Bool {
        guard key == .fileCurrentOffsetKey, let number = property as? NSNumber,
              number.int64Value >= 0, number.int64Value <= size else { return false }
        lock.lock()
        guard state != .closed && state != .error else { lock.unlock(); return false }
        offset = number.int64Value
        if state == .atEnd { state = .open }
        let read = pending; pending = nil
        lock.unlock()
        read?.cancel()
        return true
    }
    override func getBuffer(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
                            length len: UnsafeMutablePointer<Int>) -> Bool { false }
    override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoop.Mode) { }
    override func remove(from aRunLoop: RunLoop, forMode mode: RunLoop.Mode) { }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard len > 0 else { return 0 }
        lock.lock()
        guard state == .open || state == .atEnd else { lock.unlock(); return -1 }
        guard offset < size else { state = .atEnd; lock.unlock(); return 0 }
        guard pending == nil else { lock.unlock(); return -1 }
        if offset >= bufferStart && offset < bufferStart + Int64(buffered.count) {
            let consumed = Int(offset - bufferStart)
            let count = min(len, buffered.count - consumed)
            buffered.copyBytes(to: buffer, from: consumed..<(consumed + count))
            offset += Int64(count)
            lock.unlock()
            return count
        }
        let start = offset
        // VLC may ask for a few KiB at a time. Coalesce those reads into one SMB
        // request instead of paying a network round trip for every decoder read.
        let count = Int(min(Int64(512 * 1024), size - start))
        let operation = StreamRead()
        pending = operation
        lock.unlock()
        operation.start(range: start..<(start + Int64(count)), load: load)
        let result = operation.wait(timeout: timeout)
        lock.lock()
        defer { lock.unlock() }
        guard pending === operation, state == .open else { return -1 }
        pending = nil
        switch result {
        case .success(let data):
            guard !data.isEmpty, data.count <= count else {
                failure = NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)); state = .error
                return -1
            }
            buffered = data; bufferStart = start
            let delivered = min(len, data.count)
            data.copyBytes(to: buffer, count: delivered)
            offset += Int64(delivered)
            return delivered
        case .failure(let error):
            failure = error; state = .error
            if !(error is CancellationError) { DiagnosticStore.shared.recordError(.mediaReadFailed, error: error) }
            return -1
        }
    }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}

private final class StreamRead: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var result: Result<Data, Error>?
    private var task: Task<Void, Never>?
    func start(range: Range<Int64>, load: @escaping SMBInputStream.Load) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        task = Task.detached { [self] in
            do { finish(.success(try await load(range))) }
            catch { finish(.failure(error)) }
        }
        lock.unlock()
    }
    func finish(_ value: Result<Data, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value; task = nil
        lock.unlock(); signal.signal()
    }
    func cancel() {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = .failure(CancellationError())
        let current = task; task = nil
        lock.unlock()
        current?.cancel()
        signal.signal()
    }
    func wait(timeout: TimeInterval) -> Result<Data, Error> {
        if signal.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock(); let current = task; lock.unlock()
            current?.cancel()
            finish(.failure(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
        }
        lock.lock(); defer { lock.unlock() }
        return result ?? .failure(CancellationError())
    }
}

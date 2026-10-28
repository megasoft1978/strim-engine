import Foundation

/// One ranged GET streamed straight into `fd` at the right offset. Never logs headers (the token lives there).
final class SegmentJob: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let fd: Int32
    private let startOffset: Int64
    private let expected: Int64
    private let path: String
    private let allowFullBody: Bool
    private let onBytes: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var cont: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var received: Int64 = 0
    private var failure: Error?
    private var cancelled = false

    init(request: URLRequest, fd: Int32, startOffset: Int64, expected: Int64, path: String,
         allowFullBody: Bool, onBytes: @escaping @Sendable (Int64) -> Void) {
        self.request = request; self.fd = fd; self.startOffset = startOffset; self.expected = expected
        self.path = path; self.allowFullBody = allowFullBody; self.onBytes = onBytes
    }

    func run(configuration: URLSessionConfiguration) async throws {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled { lock.unlock(); c.resume(throwing: CancellationError()); return }
                cont = c
                let t = session.dataTask(with: request)
                task = t
                lock.unlock()
                t.resume()
            }
        } onCancel: {
            lock.lock(); cancelled = true; let t = task; lock.unlock()
            t?.cancel()
        }
    }

    private func finish(_ error: Error?) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { failure = PullError.network("not an HTTP response"); completionHandler(.cancel); return }
        switch http.statusCode {
        case 206: completionHandler(.allow)
        case 200 where startOffset == 0 && allowFullBody: completionHandler(.allow)
        case 200: failure = PullError.rangeIgnored(path); completionHandler(.cancel)
        default: failure = PullError.http(http.statusCode, path); completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var off = startOffset + received
        var ok = true
        data.withUnsafeBytes { raw in
            var p = raw.baseAddress!, left = raw.count
            while left > 0 {
                let n = pwrite(fd, p, left, off_t(off))
                if n <= 0 { ok = false; return }
                p += n; left -= n; off += Int64(n)
            }
        }
        if !ok { failure = PullError.network("write failed (disk full?)"); dataTask.cancel(); return }
        received += Int64(data.count)
        onBytes(Int64(data.count))
        if received > expected { failure = PullError.network("server sent more bytes than requested for \(path)"); dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let f = failure { finish(f) }
        else if let error {
            if (error as? URLError)?.code == .cancelled { finish(CancellationError()) }
            else { finish(PullError.network((error as? URLError).map { "\($0.code.rawValue) \($0.localizedDescription)" } ?? error.localizedDescription)) }
        } else if received != expected { finish(PullError.network("short read for \(path): \(received) of \(expected) bytes")) }
        else { finish(nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var r = newRequest
        // The signed CDN URL must not see the token; the Range header must survive the hop.
        if r.url?.host != request.url?.host { r.setValue(nil, forHTTPHeaderField: "Authorization") }
        if let range = request.value(forHTTPHeaderField: "Range") { r.setValue(range, forHTTPHeaderField: "Range") }
        completionHandler(r)
    }
}

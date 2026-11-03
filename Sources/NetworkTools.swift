import Foundation
import CFNetwork

enum NetworkState {
    /// 지금 폰에 VPN이 켜져 있는지 (켜져 있으면 측정값이 VPN을 거친 값이 됨)
    static func isVPNActive() -> Bool {
        guard let unmanaged = CFNetworkCopySystemProxySettings(),
              let settings = unmanaged.takeRetainedValue() as? [String: Any],
              let scoped = settings["__SCOPED__"] as? [String: Any] else {
            return false
        }
        let prefixes = ["tap", "tun", "ppp", "ipsec", "utun"]
        return scoped.keys.contains { key in
            prefixes.contains { key.hasPrefix($0) }
        }
    }
}

/// 몇 초 동안 받아 본 양으로 다운로드 속도(Mbps)를 잼
final class SpeedTester: NSObject, URLSessionDataDelegate {
    private static let testURL = URL(string: "https://speed.cloudflare.com/__down?bytes=25000000")!

    private let lock = NSLock()
    private var received = 0
    private var startedAt = Date()
    private var firstByteAt: Date?
    private var continuation: CheckedContinuation<Double?, Never>?
    private var session: URLSession?

    /// - duration: 이 시간 동안만 받고 멈춤
    func run(duration: TimeInterval = 7) async -> Double? {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let config = URLSessionConfiguration.ephemeral
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = duration + 5
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.session = session
            startedAt = Date()
            session.dataTask(with: Self.testURL).resume()

            DispatchQueue.global().asyncAfter(deadline: .now() + duration) { [weak self] in
                self?.finish()
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if firstByteAt == nil { firstByteAt = Date() }
        received += data.count
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish()
    }

    private func finish() {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        let bytes = received
        // 첫 바이트가 온 뒤부터 계산해야 연결 준비 시간이 빠져서 정확함
        let from = firstByteAt ?? startedAt
        let seconds = max(Date().timeIntervalSince(from), 0.3)
        lock.unlock()

        session?.invalidateAndCancel()
        session = nil
        let mbps: Double? = bytes > 50_000 ? Double(bytes) * 8 / seconds / 1_000_000 : nil
        continuation.resume(returning: mbps)
    }
}

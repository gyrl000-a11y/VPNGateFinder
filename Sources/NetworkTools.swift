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

/// 지금 바깥에서 보이는 내 IP와 나라 알아내기.
/// VPN Gate 서버 IP는 수백 명이 같이 써서 조회 횟수 제한에 잘 걸리므로
/// 여러 곳을 차례로 물어봄
enum IPLookup {
    static func lookup() async -> IPInfo? {
        // VPN Gate는 IPv4만 쓰므로 IPv4 주소로 먼저 물어봄 (5G 같은 IPv6 망에서도 VPN 경로가 보이게)
        async let v6 = cloudflareTrace("https://[2606:4700:4700::1111]/cdn-cgi/trace")
        var found = await cloudflareTrace("https://1.1.1.1/cdn-cgi/trace")
        if found == nil { found = await cloudflareTrace("https://www.cloudflare.com/cdn-cgi/trace") }
        let ipv6 = await v6

        if var info = found {
            if let ipv6, ipv6.ip != info.ip, ipv6.ip.contains(":") {
                info.ipv6 = ipv6.ip
                info.ipv6Country = ipv6.country
            }
            // 도시·통신사 정보는 있으면 덧붙이고, 실패해도 그대로 씀
            if let extra = await jsonLookup(urls: ["https://ipinfo.io/json"], timeout: 5),
               extra.ip == info.ip {
                info.city = extra.city
                info.org = extra.org
                if info.country == nil { info.country = extra.country }
            }
            return info
        }
        return await jsonLookup(urls: [
            "https://ipinfo.io/json",
            "https://ipapi.co/json/",
            "https://api.country.is/",
            "https://ifconfig.co/json",
        ], timeout: 8)
    }

    private static func fetch(_ urlString: String, timeout: TimeInterval) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let result = try? await URLSession.shared.data(for: request),
              let http = result.1 as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        return result.0
    }

    /// Cloudflare의 진단 주소. "ip=1.2.3.4", "loc=JP" 같은 줄로 답함
    private static func cloudflareTrace(_ url: String) async -> IPInfo? {
        guard let data = await fetch(url, timeout: 6),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        guard let ip = fields["ip"], !ip.isEmpty else { return nil }
        let loc = fields["loc"].flatMap { $0.count == 2 && $0 != "XX" ? $0 : nil }
        return IPInfo(ip: ip, country: loc, city: nil, org: nil)
    }

    private static func jsonLookup(urls: [String], timeout: TimeInterval) async -> IPInfo? {
        for url in urls {
            guard let data = await fetch(url, timeout: timeout),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let json = object as? [String: Any],
                  let ip = (json["ip"] ?? json["query"]) as? String, !ip.isEmpty else {
                continue
            }
            // 서비스마다 국가 코드를 담는 이름이 달라서 두 글자짜리를 찾음
            let countryKeys = ["country_iso", "country_code", "countryCode", "country"]
            let country = countryKeys
                .compactMap { json[$0] as? String }
                .first { $0.count == 2 }
            let city = json["city"] as? String
            let org = (json["org"] ?? json["asn_org"]) as? String
            return IPInfo(ip: ip, country: country, city: city, org: org)
        }
        return nil
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

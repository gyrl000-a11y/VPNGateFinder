import Foundation

/// 서버 한 대(VPN Gate 목록에서 왔거나, 사용자가 가져온 .ovpn 파일)
struct VPNServer: Identifiable, Hashable {
    enum Source: Hashable { case vpnGate, imported }

    let id: String
    let hostName: String
    let ip: String              // 가져온 파일은 도메인 주소일 수도 있음
    let score: Int
    let reportedPing: Int?      // VPN Gate 쪽에서 잰 핑(내 폰 기준 아님)
    let speedBps: Int
    let countryLong: String
    let countryShort: String
    let sessions: Int
    let uptimeMs: Int
    let operatorName: String
    let configText: String      // .ovpn 내용
    let proto: String           // "tcp" / "udp"
    let port: Int

    var source: Source = .vpnGate
    var needsAuth = false       // OpenVPN Connect에서 아이디·비밀번호를 물어봄
    var missingFiles = false    // ca.crt 같은 별도 파일을 가리키고 있어 그대로는 안 될 수 있음
    var fileName: String?       // 가져온 파일 이름
    var tlsWrapped = false      // tls-auth / tls-crypt 사용 (OpenVPN 응답 확인 불가)

    var isImported: Bool { source == .imported }

    var speedMbps: Double { Double(speedBps) / 1_000_000 }

    var uptimeText: String {
        let hours = uptimeMs / 1000 / 3600
        if hours >= 24 { return "\(hours / 24)일" }
        return "\(hours)시간"
    }

    var flag: String { isImported ? "📁" : Self.flag(for: countryShort) }

    /// 카드·목록 제목: VPN Gate는 국가 이름, 가져온 파일은 파일 이름
    var countryNameKo: String {
        if isImported {
            let name = fileName ?? hostName
            return (name as NSString).deletingPathExtension
        }
        return Self.countryName(for: countryShort, fallback: countryLong)
    }

    static func flag(for code: String) -> String {
        guard code.count == 2 else { return "🌐" }
        let base: UInt32 = 127397
        var s = ""
        for scalar in code.uppercased().unicodeScalars {
            guard let u = UnicodeScalar(base + scalar.value) else { return "🌐" }
            s.unicodeScalars.append(u)
        }
        return s
    }

    static func countryName(for code: String, fallback: String) -> String {
        Locale(identifier: "ko_KR").localizedString(forRegionCode: code) ?? fallback
    }
}

/// .ovpn 내용에서 읽어 낸 정보
struct ProfileInfo {
    var host: String?
    var proto = "udp"
    var port = 1194
    var needsAuth = false
    var missingFiles = false
    var tlsWrapped = false

    var isUsable: Bool { host != nil }

    static func inspect(_ config: String) -> ProfileInfo {
        var info = ProfileInfo()
        var sawProto = false
        let fileKeys: Set<String> = ["ca", "cert", "key", "tls-auth", "tls-crypt", "pkcs12"]

        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if lower.hasPrefix("<tls-auth>") || lower.hasPrefix("<tls-crypt") {
                info.tlsWrapped = true
                continue
            }
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") || line.hasPrefix("<") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let key = parts.first?.lowercased() else { continue }
            if key == "tls-auth" || key.hasPrefix("tls-crypt") { info.tlsWrapped = true }

            switch key {
            case "proto" where parts.count >= 2 && !sawProto:
                info.proto = parts[1].lowercased().hasPrefix("tcp") ? "tcp" : "udp"
                sawProto = true
            case "remote" where info.host == nil && parts.count >= 2:
                info.host = parts[1]
                if parts.count >= 3, let p = Int(parts[2]) { info.port = p }
                // remote 줄 끝에 프로토콜이 붙는 경우: remote host 443 tcp
                if parts.count >= 4, !sawProto {
                    info.proto = parts[3].lowercased().hasPrefix("tcp") ? "tcp" : "udp"
                    sawProto = true
                }
            case "port" where parts.count >= 2:
                if let p = Int(parts[1]) { info.port = p }
            case "auth-user-pass":
                info.needsAuth = true
            default:
                // <ca>...</ca>처럼 안에 들어 있지 않고 "ca ca.crt"처럼 파일을 가리키는 경우
                if fileKeys.contains(key), parts.count >= 2, parts[1] != "[inline]" {
                    info.missingFiles = true
                }
            }
        }
        return info
    }
}

/// VPN Gate API (CSV) 받아오기와 해석
enum VPNGateAPI {
    // VPN Gate API는 http만 제공해서 Info.plist에 예외를 넣어 둠
    /// https를 먼저 쓰고, 안 되면 http로 다시 시도.
    /// http는 통신사 와이파이나 중간 장비에서 막히거나 다른 페이지로 바뀌기 쉬움
    static let urls = [
        URL(string: "https://www.vpngate.net/api/iphone/")!,
        URL(string: "http://www.vpngate.net/api/iphone/")!,
    ]

    enum APIError: LocalizedError {
        case badResponse, empty, failed(String)
        var errorDescription: String? {
            switch self {
            case .badResponse: return "VPN Gate 목록을 읽지 못했어요."
            case .empty: return "지금 연결 가능한 VPN Gate 서버가 없어요."
            case .failed(let reason): return reason
            }
        }
    }

    /// 목록을 받아서 해석한 서버들과 원본 텍스트(저장용)를 돌려줌
    static func fetch() async throws -> (servers: [VPNServer], raw: String) {
        var lastReason = "VPN Gate 목록을 받지 못했어요."
        for url in urls {
            let request = URLRequest(url: url,
                                     cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: 20)
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    lastReason = "VPN Gate 서버가 응답 코드 \(http.statusCode)를 보냈어요."
                    continue
                }
                guard let text = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1) else {
                    lastReason = "VPN Gate 목록을 읽지 못했어요."
                    continue
                }
                let servers = parse(text)
                if servers.isEmpty {
                    // 차단 안내 페이지 같은 엉뚱한 내용이 온 경우
                    lastReason = "VPN Gate 대신 다른 페이지가 받아졌어요. 이 네트워크에서 막혀 있을 수 있어요."
                    continue
                }
                return (servers, text)
            } catch let error as URLError where error.code == .timedOut {
                lastReason = "VPN Gate 서버가 응답하지 않아요(시간 초과)."
            } catch {
                lastReason = "VPN Gate에 연결하지 못했어요."
            }
        }
        throw APIError.failed(lastReason)
    }

    /// 형식: 1행 "*vpn_servers", 2행 "#HostName,IP,Score,...", 데이터 행들, 마지막 "*"
    static func parse(_ text: String) -> [VPNServer] {
        var result: [VPNServer] = []
        var seen = Set<String>()

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("*") || line.hasPrefix("#") { continue }

            let cols = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 15, let b64 = cols.last, !b64.isEmpty else { continue }

            guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
                  let config = String(data: data, encoding: .utf8) else { continue }

            let info = ProfileInfo.inspect(config)
            let id = "gate|" + cols[0] + "|" + cols[1]
            if seen.contains(id) { continue }
            seen.insert(id)

            result.append(VPNServer(
                id: id,
                hostName: cols[0],
                ip: cols[1],
                score: Int(cols[2]) ?? 0,
                reportedPing: Int(cols[3]),
                speedBps: Int(cols[4]) ?? 0,
                countryLong: cols[5],
                countryShort: cols[6],
                sessions: Int(cols[7]) ?? 0,
                uptimeMs: Int(cols[8]) ?? 0,
                operatorName: cols[12],
                configText: config,
                proto: info.proto,
                port: info.port,
                tlsWrapped: info.tlsWrapped
            ))
        }
        return result
    }
}

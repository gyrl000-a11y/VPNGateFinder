import Foundation

/// VPN Gate 누적 미러 (github.com/GeorgeXie2333/vpngate-list-mirror)
/// 공식 목록(약 100개)에 한 번이라도 나왔던 서버를 최대 7일 동안 모아 두고,
/// 30분마다 다시 접속을 시도해 결과를 같이 적어 둠.
enum PoolAPI {
    static let base = "https://raw.githubusercontent.com/GeorgeXie2333/vpngate-list-mirror/main/"
    static var listURL: URL { URL(string: base + "pool/servers.json")! }

    /// 받은 목록에서 이 기준보다 오래 확인 안 된 서버는 뺌
    static let tcpFreshHours: Double = 24
    static let udpFreshHours: Double = 48

    enum PoolError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            if case .failed(let reason) = self { return reason }
            return nil
        }
    }

    // MARK: - JSON 형식

    private struct PoolFile: Decodable {
        let servers: [Entry]
    }

    private struct Entry: Decodable {
        let id: String
        let hostname: String?
        let ip: String
        let country_code: String?
        let country_name: String?
        let score: Int?
        let ping_ms: Int?
        let speed_bps: Int?
        let num_vpn_sessions: Int?
        let last_seen_at: String?
        let present_in_latest_source: Bool?
        let probe_reason: String?
        let probe_targets: [Target]?
        let tcp_probe: TCPProbe?
        let config: ConfigRef?
    }

    private struct Target: Decodable { let ip: String?; let port: Int? }
    private struct TCPProbe: Decodable {
        let status: String?
        let last_success_at: String?
        let consecutive_failures: Int?
    }
    private struct ConfigRef: Decodable { let path: String? }
    private struct ConfigFile: Decodable { let openvpn_config_base64: String }

    // 서버가 수천 개라 날짜 변환기는 한 번만 만들어 둠
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plainFormatter = ISO8601DateFormatter()

    private static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        return fractionalFormatter.date(from: string) ?? plainFormatter.date(from: string)
    }

    // MARK: - 받아오기

    /// 원본 바이트를 돌려줌 (저장해 두고 다음에 바로 쓰려고)
    static func download() async throws -> Data {
        let request = URLRequest(url: listURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 40)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw PoolError.failed("확장 목록 서버가 응답 코드 \(http.statusCode)를 보냈어요.")
            }
            return data
        } catch let error as PoolError {
            throw error
        } catch {
            throw PoolError.failed("확장 목록을 받지 못했어요.")
        }
    }

    /// 최근에 살아 있던 서버만 골라 VPNServer로 바꿈. 설정 파일은 나중에 따로 받음
    static func parse(_ data: Data, now: Date = Date()) -> [VPNServer] {
        guard let file = try? JSONDecoder().decode(PoolFile.self, from: data) else { return [] }
        var result: [VPNServer] = []
        result.reserveCapacity(1500)

        for e in file.servers {
            // 공식 목록에 지금 있는 서버는 공식 목록 쪽을 씀
            if e.present_in_latest_source == true { continue }
            guard let path = e.config?.path, !path.isEmpty else { continue }

            let isTCP = e.probe_reason == "tcp"
            let lastSeen = date(e.last_seen_at)
            if isTCP {
                guard let probe = e.tcp_probe else { continue }
                if probe.status == "unreachable" { continue }
                // 미러가 직접 접속에 성공한 지 오래된 서버는 뺌
                guard let ok = date(probe.last_success_at),
                      now.timeIntervalSince(ok) < tcpFreshHours * 3600 else { continue }
            } else {
                guard let seen = lastSeen,
                      now.timeIntervalSince(seen) < udpFreshHours * 3600 else { continue }
            }

            let code = (e.country_code ?? "").uppercased()
            let port = e.probe_targets?.first?.port ?? 1194

            var server = VPNServer(
                id: "pool|" + e.id,
                hostName: e.hostname ?? e.ip,
                ip: e.ip,
                score: e.score ?? 0,
                reportedPing: e.ping_ms,
                speedBps: e.speed_bps ?? 0,
                countryLong: e.country_name ?? code,
                countryShort: code,
                sessions: e.num_vpn_sessions ?? 0,
                uptimeMs: 0,
                operatorName: "",
                configText: "",
                proto: isTCP ? "tcp" : "udp",
                port: port
            )
            server.source = .pool
            server.configPath = path
            server.lastSeen = lastSeen
            result.append(server)
        }
        return result
    }

    /// 서버 하나의 .ovpn 설정 받기
    static func fetchConfig(path: String) async -> String? {
        guard let url = URL(string: base + path) else { return nil }
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
        guard let result = try? await URLSession.shared.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let file = try? JSONDecoder().decode(ConfigFile.self, from: result.0),
              let raw = Data(base64Encoded: file.openvpn_config_base64, options: .ignoreUnknownCharacters),
              let text = String(data: raw, encoding: .utf8) else {
            return nil
        }
        return text
    }
}

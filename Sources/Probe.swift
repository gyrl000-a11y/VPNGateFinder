import Foundation
import Network

/// 서버 응답 확인 결과
struct ProbeResult: Hashable {
    let ms: Int
    /// true: OpenVPN 서버가 직접 대답함 / false: 포트가 열린 것만 확인
    let verified: Bool
}

/// 내 폰에서 서버까지 실제로 응답이 오는지, 얼마나 걸리는지 확인
enum Probe {

    /// 서버 하나 확인. 결과가 nil이면 응답 없음
    static func check(_ server: VPNServer, timeout: TimeInterval = 3) async -> ProbeResult? {
        // tls-auth/tls-crypt가 걸린 서버는 서명 없는 첫 패킷을 무시하므로 OpenVPN 확인을 할 수 없음
        if !server.tlsWrapped {
            if let ms = await openVPNHandshake(host: server.ip, port: server.port,
                                               tcp: server.proto == "tcp", timeout: timeout) {
                return ProbeResult(ms: ms, verified: true)
            }
            // OpenVPN 응답이 없어도 TCP 포트가 열려 있으면 일단 후보로 둠
        }
        if server.proto == "tcp",
           let ms = await tcpConnect(host: server.ip, port: server.port, timeout: timeout) {
            return ProbeResult(ms: ms, verified: false)
        }
        return nil
    }

    // MARK: - OpenVPN 첫 인사 패킷

    /// P_CONTROL_HARD_RESET_CLIENT_V2: opcode 7, key id 0 → 0x38
    /// [0x38][세션 ID 8바이트][ACK 개수 0][패킷 ID 0 4바이트] = 14바이트
    private static func resetPacket(tcp: Bool) -> Data {
        var body: [UInt8] = [0x38]
        for _ in 0..<8 { body.append(UInt8.random(in: 0...255)) }
        body.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00])
        if tcp {
            // TCP는 앞에 2바이트 길이가 붙음
            return Data([UInt8(body.count >> 8), UInt8(body.count & 0xff)] + body)
        }
        return Data(body)
    }

    /// 서버가 P_CONTROL_HARD_RESET_SERVER_V2(opcode 8)로 답했는지
    private static func isServerReset(_ data: Data, tcp: Bool) -> Bool {
        let bytes = [UInt8](data)
        let index = tcp ? 2 : 0
        guard bytes.count > index else { return false }
        return (bytes[index] >> 3) == 8
    }

    static func openVPNHandshake(host: String, port: Int, tcp: Bool, timeout: TimeInterval) async -> Int? {
        guard let nwPort = makePort(port) else { return nil }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort,
                                      using: tcp ? .tcp : .udp)
        let queue = DispatchQueue(label: "probe.ovpn.\(host)")
        let once = Once()
        let packet = resetPacket(tcp: tcp)

        return await withCheckedContinuation { continuation in
            func finish(_ value: Int?) {
                guard once.claim() else { return }
                continuation.resume(returning: value)
                connection.cancel()
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let sentAt = DispatchTime.now().uptimeNanoseconds
                    connection.send(content: packet, completion: .contentProcessed { error in
                        if error != nil { finish(nil) }
                    })
                    let handler: (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void = { data, _, _, error in
                        guard error == nil, let data, isServerReset(data, tcp: tcp) else {
                            finish(nil); return
                        }
                        finish(Int((DispatchTime.now().uptimeNanoseconds - sentAt) / 1_000_000))
                    }
                    if tcp {
                        connection.receive(minimumIncompleteLength: 3, maximumLength: 4096, completion: handler)
                    } else {
                        connection.receiveMessage(completion: handler)
                    }
                case .failed, .waiting, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    // MARK: - TCP 연결만 확인

    static func tcpConnect(host: String, port: Int, timeout: TimeInterval) async -> Int? {
        guard let nwPort = makePort(port) else { return nil }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "probe.tcp.\(host)")
        let once = Once()
        let start = DispatchTime.now().uptimeNanoseconds

        return await withCheckedContinuation { continuation in
            func finish(_ value: Int?) {
                guard once.claim() else { return }
                continuation.resume(returning: value)
                connection.cancel()
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000))
                case .failed, .waiting, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    // MARK: - 도우미

    private static func makePort(_ port: Int) -> NWEndpoint.Port? {
        guard port > 0, port <= 65535 else { return nil }
        return NWEndpoint.Port(rawValue: UInt16(port))
    }

    /// continuation을 한 번만 끝내도록 막는 장치
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}

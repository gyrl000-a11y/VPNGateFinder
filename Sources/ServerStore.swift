import Foundation

struct CountryOption: Hashable, Identifiable {
    let code: String
    let name: String
    let count: Int
    var id: String { code }
}

struct ImportResult {
    var added: [String] = []
    var rejected: [String] = []
    var needsAuth = 0
    var missingFiles = 0
}

struct IPInfo: Equatable {
    var ip: String
    var country: String?   // 두 글자 국가 코드 (JP 등)
    var city: String?
    var org: String?
}

/// 자동 선택 기준
enum PickMode: String, CaseIterable, Identifiable {
    case fastest   // 응답이 빠른 서버
    case roomy     // 응답하는 서버 중 덜 붐비고 속도가 높은 서버

    var id: String { rawValue }
    var label: String {
        switch self {
        case .fastest: return "응답 빠른 순"
        case .roomy: return "덜 붐비고 빠른 순"
        }
    }

    static var current: PickMode {
        PickMode(rawValue: UserDefaults.standard.string(forKey: "pickMode") ?? "") ?? .fastest
    }
}

@MainActor
final class ServerStore: ObservableObject {
    static let allCountries = "ALL"
    static let myFiles = "MINE"
    /// '연결이 안 돼요'로 제외한 서버를 다시 후보에 넣기까지의 시간
    static let excludeDuration: TimeInterval = 24 * 3600

    /// 화면에 보이는 VPN Gate 서버 (공식 목록 + 켜져 있으면 확장 목록)
    @Published private(set) var servers: [VPNServer] = []
    @Published private(set) var imported: [VPNServer] = []    // 내 설정 파일

    private var official: [VPNServer] = []   // 공식 API
    private var pool: [VPNServer] = []       // 누적 미러
    /// 누적 미러 서버의 설정 파일 (서버 id → .ovpn 내용)
    private var poolConfigs: [String: String] = [:]
    @Published private(set) var poolUpdated: Date?
    @Published private(set) var poolCount = 0
    @Published private(set) var poolLoading = false
    @Published var poolError: String?

    /// 확장 목록 사용 여부 (설정 화면의 스위치와 같은 값)
    var usePool: Bool { UserDefaults.standard.object(forKey: "usePool") as? Bool ?? true }
    /// 누적 미러는 30분마다 갱신되므로 그보다 자주 받지 않음
    private static let poolRefreshInterval: TimeInterval = 25 * 60
    @Published private(set) var isLoading = false
    @Published private(set) var isTesting = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var usingCachedList = false
    @Published var errorMessage: String?

    /// 서버 id → 응답 확인 결과. 값이 nil이면 응답 없음, 키가 없으면 아직 안 잼
    @Published private(set) var measured: [String: ProbeResult?] = [:]
    @Published private(set) var best: VPNServer?
    @Published private(set) var bestFileURL: URL?

    /// 서버 id → 제외한 시각 (앱을 껐다 켜도 유지)
    @Published private(set) var excluded: [String: Date] = [:]
    /// '다른 서버'로 이번에 건너뛴 서버들 (앱을 끄면 사라짐)
    private var sessionSkip = Set<String>()
    private var pickGeneration = 0

    /// 서버 id → 실제로 연결이 확인된 마지막 시각 (7일간 기억)
    @Published private(set) var successes: [String: Date] = [:]
    static let successMemory: TimeInterval = 7 * 24 * 3600

    /// 목록 전체 확인 중
    @Published private(set) var isScanning = false
    @Published private(set) var scanProgress = 0
    @Published private(set) var scanTotal = 0

    // 내 IP 확인
    @Published private(set) var ipInfo: IPInfo?
    @Published private(set) var ipChecking = false
    @Published private(set) var ipError: String?

    // VPN 켜짐 여부와 속도 측정
    @Published private(set) var vpnActive = false
    @Published private(set) var speedMbps: Double?
    @Published private(set) var speedTesting = false
    @Published private(set) var speedError: String?

    init() {
        loadImported()
        loadExcluded()
        loadSuccesses()
        loadCachedList()
        refreshVPNState()
        Task { await loadCachedPool() }
    }

    /// 공식 목록과 확장 목록을 합쳐 화면용 목록을 다시 만듦
    private func rebuildServers() {
        guard usePool, !pool.isEmpty else {
            servers = official
            return
        }
        let officialIPs = Set(official.map(\.ip))
        var extra: [VPNServer] = []
        extra.reserveCapacity(pool.count)
        for var s in pool where !officialIPs.contains(s.ip) {
            if let text = poolConfigs[s.id] { Self.apply(config: text, to: &s) }
            extra.append(s)
        }
        servers = official + extra
    }

    /// 확장 목록 스위치를 바꿨을 때
    func usePoolChanged() async {
        if usePool && pool.isEmpty {
            await refreshPool(force: true)
        }
        rebuildServers()
    }

    private static func apply(config text: String, to server: inout VPNServer) {
        let info = ProfileInfo.inspect(text)
        server.configText = text
        server.proto = info.proto
        server.port = info.port
        server.tlsWrapped = info.tlsWrapped
    }

    /// 확장 목록 서버는 설정 파일을 고를 때 받아 옴. 실패하면 nil
    func resolve(_ server: VPNServer) async -> VPNServer? {
        guard server.needsConfig, let path = server.configPath else { return server }
        if let text = poolConfigs[server.id] {
            var s = server
            Self.apply(config: text, to: &s)
            return s
        }
        guard let text = await PoolAPI.fetchConfig(path: path) else { return nil }
        poolConfigs[server.id] = text
        var s = server
        Self.apply(config: text, to: &s)
        if let i = servers.firstIndex(where: { $0.id == s.id }) { servers[i] = s }
        return s
    }

    /// 여러 서버를 한꺼번에 준비. 설정 파일을 못 받은 서버는 빠짐
    private func resolveAll(_ list: [VPNServer]) async -> [VPNServer] {
        let need = list.filter { $0.needsConfig && poolConfigs[$0.id] == nil }
        if !need.isEmpty {
            var fetched: [String: String] = [:]
            await withTaskGroup(of: (String, String?).self) { group in
                for s in need {
                    let id = s.id, path = s.configPath ?? ""
                    group.addTask {
                        let text = await PoolAPI.fetchConfig(path: path)
                        return (id, text)
                    }
                }
                for await (id, text) in group {
                    if let text { fetched[id] = text }
                }
            }
            poolConfigs.merge(fetched) { $1 }
        }
        var out: [VPNServer] = []
        for var s in list {
            if s.needsConfig {
                guard let text = poolConfigs[s.id] else { continue }
                Self.apply(config: text, to: &s)
                if let i = servers.firstIndex(where: { $0.id == s.id }) { servers[i] = s }
            }
            out.append(s)
        }
        return out
    }

    // MARK: - 확장 목록 받기와 저장

    private var poolCacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("vpngate-pool.json")
    }

    private func loadCachedPool() async {
        let url = poolCacheURL
        guard let data = try? Data(contentsOf: url) else { return }
        let list = await Task.detached(priority: .userInitiated) { PoolAPI.parse(data) }.value
        guard !list.isEmpty, pool.isEmpty else { return }
        pool = list
        poolCount = list.count
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        poolUpdated = attrs?[.modificationDate] as? Date
        rebuildServers()
    }

    /// 확장 목록 새로 받기. 최근에 받았으면 건너뜀
    func refreshPool(force: Bool = false) async {
        guard usePool, !poolLoading else { return }
        if !force, let updated = poolUpdated, !pool.isEmpty,
           Date().timeIntervalSince(updated) < Self.poolRefreshInterval {
            return
        }
        poolLoading = true
        defer { poolLoading = false }
        do {
            let data = try await PoolAPI.download()
            let list = await Task.detached(priority: .userInitiated) { PoolAPI.parse(data) }.value
            guard !list.isEmpty else {
                poolError = "확장 목록을 읽지 못했어요."
                return
            }
            pool = list
            poolCount = list.count
            poolUpdated = Date()
            poolError = nil
            try? data.write(to: poolCacheURL, options: .atomic)
        } catch {
            poolError = (error as? LocalizedError)?.errorDescription ?? "확장 목록을 받지 못했어요."
        }
    }

    // MARK: - 목록

    var countries: [CountryOption] {
        let grouped = Dictionary(grouping: servers, by: \.countryShort)
        return grouped.map { code, list in
            CountryOption(code: code,
                          name: VPNServer.countryName(for: code, fallback: list.first?.countryLong ?? code),
                          count: list.count)
        }
        .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }

    /// VPN Gate 서버만, 점수순
    func filtered(country: String, tcpOnly: Bool) -> [VPNServer] {
        guard country != Self.myFiles else { return [] }
        return servers
            .filter { country == Self.allCountries || $0.countryShort == country }
            .filter { !tcpOnly || $0.proto == "tcp" }
            .sorted { $0.score > $1.score }
    }

    /// 자동 선택 때 확인할 후보 (제외·건너뛴 서버는 빼고)
    func candidates(country: String, tcpOnly: Bool, includeImported: Bool,
                    skip: Set<String> = [], gateCount: Int = 10) -> [VPNServer] {
        let usable: (VPNServer) -> Bool = { [self] s in !isExcluded(s) && !skip.contains(s.id) }
        let mine = imported.filter { (!tcpOnly || $0.proto == "tcp") && usable($0) }
        if country == Self.myFiles { return mine }
        let gate = filtered(country: country, tcpOnly: tcpOnly).filter(usable)   // 점수순

        var list: [VPNServer]
        switch PickMode.current {
        case .fastest:
            list = Array(gate.prefix(gateCount))
        case .roomy:
            // 속도 ÷ 접속자 수가 큰 서버 위주로, 점수 상위 몇 개도 같이 봄
            let roomy = gate.filter { $0.speedBps > 0 }
                .sorted { $0.roomScore > $1.roomScore }
                .prefix(gateCount + 4)
            list = Array(roomy)
            let picked = Set(list.map(\.id))
            list += gate.filter { !picked.contains($0.id) }.prefix(4)
        }
        // 위 후보 밖이라도 최근에 연결이 됐던 서버는 후보에 넣음
        let ids = Set(list.map(\.id))
        list += gate.filter { hasWorked($0) && !ids.contains($0.id) }
        if includeImported { list += mine }
        return list
    }

    // MARK: - 받아오기와 고르기

    /// VPN Gate 목록을 새로 받고 최적 서버까지 고름
    func refreshAndPick(country: String, tcpOnly: Bool, includeImported: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        refreshVPNState()

        // 공식 목록과 확장 목록을 동시에 받음
        async let poolTask: Void = refreshPool()
        do {
            let result = try await VPNGateAPI.fetch()
            official = result.servers
            lastUpdated = Date()
            usingCachedList = false
            measured = measured.filter { !$0.key.hasPrefix("gate|") }
            sessionSkip.removeAll()
            saveCachedList(result.raw)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "VPN Gate 목록을 받지 못했어요."
            if official.isEmpty && pool.isEmpty {
                errorMessage = "\(reason) 인터넷 연결을 확인해 주세요."
            } else {
                errorMessage = "\(reason) 저장해 둔 목록으로 보여 드려요."
            }
        }
        await poolTask
        rebuildServers()
        isLoading = false
        // VPN Gate가 실패해도 저장된 목록이나 내 파일이 있으면 그걸로 고름
        await pickBest(country: country, tcpOnly: tcpOnly, includeImported: includeImported)
    }

    /// 후보들에 실제로 연결해 보고 가장 빨리 대답하는 서버를 고름
    /// - skipCurrent: 지금 고른 서버를 건너뛰고 다음 서버를 고름
    func pickBest(country: String, tcpOnly: Bool, includeImported: Bool, skipCurrent: Bool = false) async {
        if skipCurrent, let current = best { sessionSkip.insert(current.id) }

        var list = candidates(country: country, tcpOnly: tcpOnly,
                              includeImported: includeImported, skip: sessionSkip)
        if list.isEmpty && !sessionSkip.isEmpty {
            // 한 바퀴 다 돌았으면 처음부터 다시
            sessionSkip.removeAll()
            list = candidates(country: country, tcpOnly: tcpOnly, includeImported: includeImported)
        }

        // 고르는 도중에 국가를 바꾸는 등 새로 고르기가 시작되면 이전 결과는 버림
        pickGeneration += 1
        let generation = pickGeneration

        best = nil
        bestFileURL = nil
        guard !list.isEmpty else { isTesting = false; return }

        isTesting = true
        defer { if generation == pickGeneration { isTesting = false } }

        // 확장 목록 서버는 설정 파일부터 받아야 포트·방식을 알 수 있음
        list = await resolveAll(list)
        guard generation == pickGeneration else { return }

        var results: [String: ProbeResult?] = [:]
        await withTaskGroup(of: (String, ProbeResult?).self) { group in
            for server in list {
                group.addTask {
                    let result = await Probe.check(server)
                    return (server.id, result)
                }
            }
            for await (id, result) in group {
                results[id] = result
            }
        }
        for server in list {
            measured[server.id] = results[server.id] ?? nil
        }
        guard generation == pickGeneration else { return }

        let reachable = list.compactMap { s -> (VPNServer, ProbeResult)? in
            guard let r = results[s.id] ?? nil else { return nil }
            return (s, r)
        }

        let sorted: [(VPNServer, ProbeResult)]
        switch PickMode.current {
        case .fastest:
            // 순서: OpenVPN이 직접 대답함 > 최근에 연결이 됐던 서버 > 응답 빠른 순
            var tiers: [String: Int] = [:]
            for (s, r) in reachable {
                tiers[s.id] = (r.verified ? 0 : 2) + (hasWorked(s) ? 0 : 1)
            }
            sorted = reachable.sorted { a, b in
                let ta = tiers[a.0.id] ?? 9, tb = tiers[b.0.id] ?? 9
                if ta != tb { return ta < tb }
                return a.1.ms < b.1.ms
            }
        case .roomy:
            // 순서: OpenVPN이 직접 대답함 > (속도 ÷ 접속자) 큰 순, 응답이 느리면 깎음
            func value(_ s: VPNServer, _ r: ProbeResult) -> Double {
                let boost = hasWorked(s) ? 1.5 : 1.0
                return s.roomScore * boost / (1 + Double(r.ms) / 150)
            }
            sorted = reachable.sorted { a, b in
                if a.1.verified != b.1.verified { return a.1.verified }
                let va = value(a.0, a.1), vb = value(b.0, b.1)
                if va != vb { return va > vb }
                return a.1.ms < b.1.ms
            }
        }
        best = sorted.first?.0

        if let chosen = best {
            bestFileURL = try? exportFile(for: chosen)
        }
    }

    /// 목록에서 직접 고른 서버를 '자동 선택' 자리에 올림
    func choose(_ server: VPNServer) async {
        guard let ready = await resolve(server) else {
            errorMessage = "이 서버의 설정 파일을 받지 못했어요. 다른 서버를 골라 주세요."
            return
        }
        best = ready
        bestFileURL = try? exportFile(for: ready)
    }

    /// 지금 보이는 목록의 서버들을 한꺼번에 확인 (최대 80개, 12개씩)
    func measureAll(_ list: [VPNServer]) async {
        guard !isScanning, !isTesting else { return }
        let targets = Array(list.prefix(80))
        isScanning = true
        scanTotal = targets.count
        scanProgress = 0
        defer { isScanning = false }

        var start = 0
        while start < targets.count {
            let raw = Array(targets[start..<min(start + 12, targets.count)])
            let chunk = await resolveAll(raw)
            // 설정 파일을 못 받은 서버는 응답 없음으로 표시
            for s in raw where !chunk.contains(where: { $0.id == s.id }) {
                measured[s.id] = .some(nil)
            }
            var results: [String: ProbeResult?] = [:]
            await withTaskGroup(of: (String, ProbeResult?).self) { group in
                for server in chunk {
                    group.addTask {
                        let result = await Probe.check(server)
                        return (server.id, result)
                    }
                }
                for await (id, result) in group {
                    results[id] = result
                }
            }
            for server in chunk {
                measured[server.id] = results[server.id] ?? nil
            }
            start += raw.count
            scanProgress = start
        }
    }

    // MARK: - 성공 기록

    func hasWorked(_ server: VPNServer) -> Bool {
        guard let at = successes[server.id] else { return false }
        return Date().timeIntervalSince(at) < Self.successMemory
    }

    private func recordSuccess(_ server: VPNServer) {
        successes[server.id] = Date()
        excluded[server.id] = nil
        saveSuccesses()
        saveExcluded()
    }

    private func loadSuccesses() {
        let raw = UserDefaults.standard.dictionary(forKey: "successes") as? [String: Double] ?? [:]
        let now = Date()
        successes = raw.mapValues { Date(timeIntervalSince1970: $0) }
            .filter { now.timeIntervalSince($0.value) < Self.successMemory }
    }

    private func saveSuccesses() {
        UserDefaults.standard.set(successes.mapValues { $0.timeIntervalSince1970 }, forKey: "successes")
    }

    // MARK: - VPN 상태와 속도

    func refreshVPNState() {
        vpnActive = NetworkState.isVPNActive()
    }

    func runSpeedTest() async {
        guard !speedTesting else { return }
        speedTesting = true
        speedError = nil
        defer { speedTesting = false }
        let tester = SpeedTester()
        if let mbps = await tester.run() {
            speedMbps = mbps
        } else {
            speedMbps = nil
            speedError = "속도를 재지 못했어요. 연결이 너무 느리거나 끊겼을 수 있어요."
        }
    }

    /// 서버 하나만 다시 확인
    func measure(_ server: VPNServer) async {
        guard let ready = await resolve(server) else {
            measured[server.id] = .some(nil)
            return
        }
        let result = await Probe.check(ready)
        measured[server.id] = result
    }

    // MARK: - 제외 목록

    func isExcluded(_ server: VPNServer) -> Bool {
        guard let at = excluded[server.id] else { return false }
        return Date().timeIntervalSince(at) < Self.excludeDuration
    }

    var activeExcludedCount: Int {
        excluded.values.filter { Date().timeIntervalSince($0) < Self.excludeDuration }.count
    }

    func setExcluded(_ server: VPNServer, _ on: Bool) {
        excluded[server.id] = on ? Date() : nil
        saveExcluded()
    }

    /// '연결이 안 돼요': 24시간 제외하고 다음 서버를 고름
    func markFailed(country: String, tcpOnly: Bool, includeImported: Bool) async {
        if let current = best { setExcluded(current, true) }
        await pickBest(country: country, tcpOnly: tcpOnly, includeImported: includeImported)
    }

    func clearExcluded() {
        excluded = [:]
        saveExcluded()
    }

    private func loadExcluded() {
        let raw = UserDefaults.standard.dictionary(forKey: "excluded") as? [String: Double] ?? [:]
        let now = Date()
        excluded = raw.mapValues { Date(timeIntervalSince1970: $0) }
            .filter { now.timeIntervalSince($0.value) < Self.excludeDuration }
    }

    private func saveExcluded() {
        let raw = excluded.mapValues { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(raw, forKey: "excluded")
    }

    // MARK: - VPN Gate 목록 저장 (다음에 열 때 바로 보이게)

    private var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("vpngate-list.csv")
    }

    private func loadCachedList() {
        guard let text = try? String(contentsOf: cacheURL, encoding: .utf8) else { return }
        let list = VPNGateAPI.parse(text)
        guard !list.isEmpty else { return }
        official = list
        servers = list
        usingCachedList = true
        let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path)
        lastUpdated = attrs?[.modificationDate] as? Date
    }

    private func saveCachedList(_ text: String) {
        try? text.write(to: cacheURL, atomically: true, encoding: .utf8)
    }

    // MARK: - 내 IP 확인

    /// 지금 바깥에서 보이는 내 IP와 나라. VPN이 켜졌는지 확인용
    func checkIP() async {
        guard !ipChecking else { return }
        ipChecking = true
        defer { ipChecking = false }
        if let info = await IPLookup.lookup() {
            if info.ip != ipInfo?.ip { speedMbps = nil }   // 연결이 바뀌면 이전 속도는 지움
            ipInfo = info
            ipError = nil
        } else {
            ipError = "IP를 확인하지 못했어요. 인터넷이 연결돼 있는지 확인하고 다시 눌러 주세요."
        }
        refreshVPNState()
        // 지금 IP가 목록의 서버와 같으면 '연결이 됐던 서버'로 기억
        if let server = connectedServer { recordSuccess(server) }
    }

    /// 지금 IP가 목록에 있는 서버 IP와 같으면 그 서버
    var connectedServer: VPNServer? {
        guard let ip = ipInfo?.ip else { return nil }
        return (servers + imported).first { $0.ip == ip }
    }

    // MARK: - 내 설정 파일

    private var importDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Imported", isDirectory: true)
    }

    func loadImported() {
        let fm = FileManager.default
        try? fm.createDirectory(at: importDir, withIntermediateDirectories: true)
        let files = (try? fm.contentsOfDirectory(at: importDir, includingPropertiesForKeys: nil)) ?? []
        imported = files
            .filter { $0.pathExtension.lowercased() == "ovpn" }
            .compactMap { Self.makeImported(from: $0) }
            .sorted { $0.countryNameKo.localizedStandardCompare($1.countryNameKo) == .orderedAscending }
    }

    private static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func makeImported(from url: URL) -> VPNServer? {
        guard let text = readText(url) else { return nil }
        let info = ProfileInfo.inspect(text)
        guard let host = info.host else { return nil }
        let name = url.lastPathComponent
        return VPNServer(
            id: "file|" + name,
            hostName: host,
            ip: host,
            score: 0,
            reportedPing: nil,
            speedBps: 0,
            countryLong: "",
            countryShort: "",
            sessions: 0,
            uptimeMs: 0,
            operatorName: "",
            configText: text,
            proto: info.proto,
            port: info.port,
            source: .imported,
            needsAuth: info.needsAuth,
            missingFiles: info.missingFiles,
            fileName: name,
            tlsWrapped: info.tlsWrapped
        )
    }

    /// 파일 앱에서 고른 .ovpn들을 앱 안으로 복사
    func importFiles(_ urls: [URL]) -> ImportResult {
        var result = ImportResult()
        let fm = FileManager.default
        try? fm.createDirectory(at: importDir, withIntermediateDirectories: true)

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let original = url.lastPathComponent
            guard let text = Self.readText(url) else {
                result.rejected.append(original); continue
            }
            let info = ProfileInfo.inspect(text)
            guard info.isUsable else {
                result.rejected.append(original); continue
            }

            // 이름이 겹치면 뒤에 번호를 붙임
            let stem = (original as NSString).deletingPathExtension
            var target = importDir.appendingPathComponent(stem + ".ovpn")
            var n = 2
            while fm.fileExists(atPath: target.path) {
                target = importDir.appendingPathComponent("\(stem) \(n).ovpn")
                n += 1
            }
            do {
                try text.write(to: target, atomically: true, encoding: .utf8)
                result.added.append(target.lastPathComponent)
                if info.needsAuth { result.needsAuth += 1 }
                if info.missingFiles { result.missingFiles += 1 }
            } catch {
                result.rejected.append(original)
            }
        }
        loadImported()
        return result
    }

    func deleteImported(_ server: VPNServer) {
        guard server.isImported, let name = server.fileName else { return }
        try? FileManager.default.removeItem(at: importDir.appendingPathComponent(name))
        measured[server.id] = nil
        excluded[server.id] = nil
        saveExcluded()
        if best?.id == server.id { best = nil; bestFileURL = nil }
        loadImported()
    }

    // MARK: - OpenVPN으로 넘길 파일

    func exportFile(for server: VPNServer) throws -> URL {
        guard !server.configText.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ovpn", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name: String
        if server.isImported, let fileName = server.fileName {
            name = fileName
        } else {
            let safeIP = server.ip.replacingOccurrences(of: ":", with: "-")
            name = "VPNGate-\(server.countryShort)-\(safeIP).ovpn"
        }
        let url = dir.appendingPathComponent(name)
        try server.configText.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

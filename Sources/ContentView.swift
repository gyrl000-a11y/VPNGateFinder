import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var store = ServerStore()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("country") private var country = "JP"
    @AppStorage("tcpOnly") private var tcpOnly = true
    @AppStorage("includeImported") private var includeImported = true
    @AppStorage("sortOrder") private var sortOrder = "score"
    @State private var didStart = false
    @State private var showImporter = false
    @State private var importMessage: String?

    var body: some View {
        NavigationStack {
            List {
                settingsSection
                bestSection
                ipSection
                myFilesSection
                gateListSection
            }
            .navigationTitle("무료 VPN 찾기")
            .refreshable { await refresh() }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.isLoading || store.isTesting)
                }
            }
            .task {
                // 앱을 열면 바로 목록 받기 + 최적 서버 고르기
                guard !didStart else { return }
                didStart = true
                await refresh()
            }
            .onChange(of: country) { _ in repick() }
            .onChange(of: tcpOnly) { _ in repick() }
            .onChange(of: includeImported) { _ in repick() }
            .onChange(of: scenePhase) { phase in
                guard phase == .active else { return }
                store.refreshVPNState()
                // OpenVPN에서 연결하고 돌아오면 IP를 다시 확인
                if store.ipInfo != nil || store.vpnActive {
                    Task { await store.checkIP() }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.data],
                          allowsMultipleSelection: true) { result in
                handleImport(result)
            }
            .alert("설정 파일 가져오기",
                   isPresented: Binding(get: { importMessage != nil },
                                        set: { if !$0 { importMessage = nil } })) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(importMessage ?? "")
            }
        }
    }

    private var busy: Bool { store.isLoading || store.isTesting }

    private func refresh() async {
        await store.refreshAndPick(country: country, tcpOnly: tcpOnly, includeImported: includeImported)
    }

    private func repick(skipCurrent: Bool = false) {
        guard !store.servers.isEmpty || !store.imported.isEmpty else { return }
        Task {
            await store.pickBest(country: country, tcpOnly: tcpOnly,
                                 includeImported: includeImported, skipCurrent: skipCurrent)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        let r = store.importFiles(urls)

        var lines: [String] = []
        if !r.added.isEmpty { lines.append("\(r.added.count)개를 추가했어요.") }
        if r.needsAuth > 0 { lines.append("\(r.needsAuth)개는 OpenVPN에서 아이디·비밀번호를 입력해야 해요.") }
        if r.missingFiles > 0 { lines.append("\(r.missingFiles)개는 인증서가 별도 파일로 되어 있어 연결이 안 될 수 있어요.") }
        if !r.rejected.isEmpty {
            lines.append("OpenVPN 설정 파일이 아니라서 건너뜀: " + r.rejected.joined(separator: ", "))
        }
        importMessage = lines.isEmpty ? "가져온 파일이 없어요." : lines.joined(separator: "\n")
        repick()
    }

    // MARK: - 설정

    private var settingsSection: some View {
        Section {
            Picker("국가", selection: $country) {
                Text("🌐 전체 (\(store.servers.count))").tag(ServerStore.allCountries)
                if !store.imported.isEmpty || country == ServerStore.myFiles {
                    Text("📁 내 파일만 (\(store.imported.count))").tag(ServerStore.myFiles)
                }
                ForEach(store.countries) { c in
                    Text("\(VPNServer.flag(for: c.code)) \(c.name) (\(c.count))").tag(c.code)
                }
                // 저장된 국가가 지금 목록에 없을 때도 선택 값이 유지되도록
                if country != ServerStore.allCountries,
                   country != ServerStore.myFiles,
                   !store.countries.contains(where: { $0.code == country }) {
                    Text("\(VPNServer.flag(for: country)) \(VPNServer.countryName(for: country, fallback: country)) (0)")
                        .tag(country)
                }
            }
            Toggle("TCP 서버만", isOn: $tcpOnly)
            if !store.imported.isEmpty && country != ServerStore.myFiles {
                Toggle("내 파일도 같이 비교", isOn: $includeImported)
            }
            if store.activeExcludedCount > 0 {
                Button("제외한 서버 다시 넣기 (\(store.activeExcludedCount)개)") {
                    store.clearExcluded()
                    repick()
                }
            }
        } footer: {
            Text("TCP는 대부분의 와이파이에서 잘 통하고, UDP는 더 빠를 때가 많지만 막히는 곳도 있어요.")
        }
    }

    // MARK: - 자동 선택 결과

    @ViewBuilder
    private var bestSection: some View {
        Section("자동 선택") {
            if store.isLoading {
                Label("서버 목록 받는 중…", systemImage: "arrow.down.circle")
                    .foregroundStyle(.secondary)
            } else if store.isTesting {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("후보 서버에 직접 물어보는 중…").foregroundStyle(.secondary)
                }
            } else {
                if store.vpnActive {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("VPN 연결 중", systemImage: "lock.shield.fill")
                            .font(.subheadline.bold())
                            .foregroundStyle(.green)
                        Text("새 서버를 고를 땐 OpenVPN을 끄고 새로고침하면 더 정확해요.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let message = store.errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Button("다시 시도") { Task { await refresh() } }
                    }
                }
                if let best = store.best {
                    BestServerCard(server: best, result: store.measured[best.id] ?? nil,
                                   worked: store.hasWorked(best))
                    if let url = store.bestFileURL {
                        ShareLink(item: url) {
                            Label("OpenVPN으로 보내기", systemImage: "paperplane.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                    Button {
                        repick(skipCurrent: true)
                    } label: {
                        Label("다른 서버로 바꾸기", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button(role: .destructive) {
                        Task {
                            await store.markFailed(country: country, tcpOnly: tcpOnly,
                                                   includeImported: includeImported)
                        }
                    } label: {
                        Label("연결이 안 돼요 (24시간 제외)", systemImage: "xmark.octagon")
                    }
                } else if store.errorMessage == nil && (!store.servers.isEmpty || !store.imported.isEmpty) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("조건에 맞는 서버가 응답하지 않아요.")
                        Text("다른 국가를 고르거나 'TCP 서버만'을 꺼 보세요.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 내 IP 확인

    private var ipSection: some View {
        Section {
            if let info = store.ipInfo {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(VPNServer.flag(for: info.country ?? ""))
                        Text(info.ip).font(.body.monospaced())
                    }
                    Text([info.country.map { VPNServer.countryName(for: $0, fallback: $0) },
                          info.city, info.org].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let server = store.connectedServer {
                        Label("VPN 연결됨: \(server.countryNameKo) \(server.isImported ? "" : "VPN Gate ")서버",
                              systemImage: "checkmark.shield.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                    }
                }
            }
            if let error = store.ipError {
                Text(error).font(.footnote).foregroundStyle(.orange)
            }
            Button {
                Task { await store.checkIP() }
            } label: {
                HStack {
                    Label(store.ipInfo == nil ? "지금 내 IP 확인" : "다시 확인", systemImage: "network")
                    if store.ipChecking { Spacer(); ProgressView() }
                }
            }
            .disabled(store.ipChecking)

            Button {
                Task { await store.runSpeedTest() }
            } label: {
                HStack {
                    Label("다운로드 속도 재기", systemImage: "speedometer")
                    Spacer()
                    if store.speedTesting {
                        ProgressView()
                    } else if let mbps = store.speedMbps {
                        Text(String(format: "%.1f Mbps", mbps))
                            .font(.body.monospacedDigit().bold())
                            .foregroundStyle(mbps >= 5 ? Color.green : (mbps >= 1 ? Color.orange : Color.red))
                    }
                }
            }
            .disabled(store.speedTesting)
            if let error = store.speedError {
                Text(error).font(.footnote).foregroundStyle(.orange)
            }
        } header: {
            Text("연결 확인")
        } footer: {
            Text("OpenVPN에서 연결한 뒤 돌아오면 자동으로 다시 확인해요. 나라가 바뀌었으면 VPN이 켜진 거예요. 연결이 확인된 서버는 7일 동안 기억해서 다음에 먼저 추천합니다. 속도 측정은 최대 7초, 데이터는 최대 25MB를 씁니다.")
        }
    }

    // MARK: - 내 설정 파일

    private var myFilesSection: some View {
        Section {
            ForEach(store.imported) { server in
                serverLink(server)
            }
            .onDelete { offsets in
                let targets = offsets.map { store.imported[$0] }
                targets.forEach { store.deleteImported($0) }
            }
            Button {
                showImporter = true
            } label: {
                Label("설정 파일(.ovpn) 가져오기", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("내 설정 파일 \(store.imported.count)개")
        } footer: {
            Text("다른 곳에서 받은 OpenVPN 설정 파일을 넣어 두면 VPN Gate 서버와 함께 비교해서 골라요. 왼쪽으로 밀면 삭제됩니다.")
        }
    }

    // MARK: - VPN Gate 목록

    @ViewBuilder
    private var gateListSection: some View {
        let list = sortedForDisplay(store.filtered(country: country, tcpOnly: tcpOnly))
        if !list.isEmpty {
            Section {
                Picker("정렬", selection: $sortOrder) {
                    Text("점수순").tag("score")
                    Text("속도순").tag("speed")
                    Text("응답순").tag("ping")
                }
                .pickerStyle(.segmented)

                Button {
                    Task { await store.measureAll(list) }
                } label: {
                    HStack {
                        Label(store.isScanning
                              ? "확인 중 \(store.scanProgress)/\(store.scanTotal)"
                              : "목록 전체 응답 확인",
                              systemImage: "dot.radiowaves.left.and.right")
                        if store.isScanning { Spacer(); ProgressView() }
                    }
                }
                .disabled(store.isScanning || busy)

                ForEach(list) { server in
                    serverLink(server)
                }
            } header: {
                Text("VPN Gate 서버 \(list.count)개")
            } footer: {
                if let updated = store.lastUpdated {
                    Text("\(store.usingCachedList ? "저장된 목록 · " : "")업데이트 \(updated.formatted(date: .abbreviated, time: .shortened)) · 출처 VPN Gate(쓰쿠바 대학) · 서버를 길게 누르면 메뉴가 나와요")
                }
            }
        }
    }

    // MARK: - 행 공통

    private func serverLink(_ server: VPNServer) -> some View {
        NavigationLink {
            ServerDetailView(server: server, store: store)
        } label: {
            ServerRow(server: server,
                      measurement: store.measured[server.id],
                      excluded: store.isExcluded(server),
                      worked: store.hasWorked(server))
        }
        .contextMenu {
            Button {
                store.choose(server)
            } label: {
                Label("이 서버로 정하기 (맨 위에 올리기)", systemImage: "arrow.up.to.line")
            }
            Button {
                Task { await store.measure(server) }
            } label: {
                Label("응답 다시 확인", systemImage: "bolt")
            }
            if store.isExcluded(server) {
                Button {
                    store.setExcluded(server, false)
                } label: {
                    Label("다시 후보에 넣기", systemImage: "arrow.uturn.backward")
                }
            } else {
                Button(role: .destructive) {
                    store.setExcluded(server, true)
                } label: {
                    Label("24시간 제외", systemImage: "xmark.octagon")
                }
            }
        }
    }

    private func sortedForDisplay(_ list: [VPNServer]) -> [VPNServer] {
        switch sortOrder {
        case "speed":
            return list.sorted { $0.speedBps > $1.speedBps }
        case "ping":
            return list.sorted { pingValue($0) < pingValue($1) }
        default:
            return list   // 이미 점수순
        }
    }

    /// 확인 결과 ms, 아직 안 쟀거나 응답이 없으면 맨 뒤로
    private func pingValue(_ server: VPNServer) -> Int {
        if case .some(.some(let result)) = store.measured[server.id] {
            return result.ms
        }
        return Int.max
    }
}

// MARK: - 카드와 행

struct BestServerCard: View {
    let server: VPNServer
    let result: ProbeResult?
    var worked = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(server.flag).font(.system(size: 40))
            VStack(alignment: .leading, spacing: 4) {
                Text(server.countryNameKo).font(.title3.bold()).lineLimit(2)
                Text("\(server.ip):\(server.port) · \(server.proto.uppercased())")
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 12) {
                    if let result {
                        Label("\(result.ms)ms", systemImage: "bolt.fill")
                    }
                    if server.isImported {
                        Label("내 파일", systemImage: "folder")
                    } else {
                        Label(String(format: "%.0f Mbps", server.speedMbps), systemImage: "speedometer")
                        Label("\(server.sessions)명", systemImage: "person.2")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if worked {
                    Label("최근에 연결이 됐던 서버", systemImage: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
                if let result {
                    if result.verified {
                        Label("OpenVPN 서버가 직접 응답함", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Label("포트만 열린 것을 확인 (응답은 미확인)", systemImage: "questionmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if server.needsAuth {
                    Label("OpenVPN에서 아이디·비밀번호 입력 필요", systemImage: "key.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                if server.missingFiles {
                    Label("인증서가 별도 파일이라 연결이 안 될 수 있어요", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct ServerRow: View {
    let server: VPNServer
    /// nil: 아직 안 잼, .some(nil): 응답 없음, .some(결과): 측정값
    let measurement: ProbeResult??
    let excluded: Bool
    var worked = false

    var body: some View {
        HStack(spacing: 10) {
            Text(server.flag).font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.isImported ? server.countryNameKo : server.ip)
                    .font(server.isImported ? Font.body : Font.body.monospaced())
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if worked {
                Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
            }
            if server.needsAuth {
                Image(systemName: "key.fill").font(.caption).foregroundStyle(.blue)
            }
            if server.missingFiles {
                Image(systemName: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if excluded {
                Text("제외됨").font(.caption).foregroundStyle(.secondary)
            } else {
                badge
            }
        }
        .opacity(excluded ? 0.5 : 1)
    }

    private var subtitle: String {
        if server.isImported {
            return "\(server.ip) · \(server.proto.uppercased())"
        }
        return "\(server.countryNameKo) · \(String(format: "%.0f", server.speedMbps)) Mbps · \(server.proto.uppercased())"
    }

    @ViewBuilder
    private var badge: some View {
        switch measurement {
        case .some(.some(let r)):
            let color: Color = r.ms < 150 ? .green : (r.ms < 350 ? .orange : .red)
            HStack(spacing: 3) {
                if r.verified {
                    Image(systemName: "checkmark.seal.fill").font(.caption2)
                }
                Text("\(r.ms)ms").font(.caption.bold())
            }
            .foregroundStyle(color)
        case .some(.none):
            Text("응답 없음").font(.caption).foregroundStyle(.red)
        case .none:
            EmptyView()
        }
    }
}

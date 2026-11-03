import SwiftUI

struct ServerDetailView: View {
    let server: VPNServer
    @ObservedObject var store: ServerStore
    @Environment(\.dismiss) private var dismiss
    @State private var fileURL: URL?
    @State private var isMeasuring = false
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section {
                BestServerCard(server: server, result: store.measured[server.id] ?? nil,
                               worked: store.hasWorked(server))
                Button {
                    store.choose(server)
                    dismiss()
                } label: {
                    Label("이 서버로 정하기 (첫 화면 맨 위로)", systemImage: "arrow.up.to.line")
                }
                if let fileURL {
                    ShareLink(item: fileURL) {
                        Label("OpenVPN으로 보내기", systemImage: "paperplane.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button {
                    isMeasuring = true
                    Task {
                        await store.measure(server)
                        isMeasuring = false
                    }
                } label: {
                    HStack {
                        Text("응답 다시 확인")
                        if isMeasuring { Spacer(); ProgressView() }
                    }
                }
                .disabled(isMeasuring)
                if noResponse {
                    Text("이번 확인에서는 응답이 없었어요. 서버가 꺼졌거나 지금 네트워크에서 막혀 있을 수 있어요.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if server.tlsWrapped && server.proto == "udp" {
                    Text("이 파일은 추가 보안 설정(tls-auth/tls-crypt)이 있는 UDP 서버라 앱에서 응답을 확인할 수 없어요. 직접 연결해서 확인해 주세요.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Toggle("자동 선택에서 제외 (24시간)", isOn: Binding(
                    get: { store.isExcluded(server) },
                    set: { store.setExcluded(server, $0) }
                ))
            }

            if server.isImported {
                Section("파일 정보") {
                    row("파일 이름", server.fileName ?? "-")
                    row("서버 주소", server.ip)
                    row("포트 · 프로토콜", "\(server.port) · \(server.proto.uppercased())")
                    row("아이디·비밀번호", server.needsAuth ? "필요" : "필요 없음")
                }
                if server.needsAuth {
                    Section {
                        Text("이 서버는 연결할 때 아이디·비밀번호를 물어봐요. 파일을 받은 사이트에 안내된 값을 OpenVPN Connect에서 입력하고 '저장'을 켜 두면 다음부터는 안 물어봅니다.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("이 파일 삭제", role: .destructive) { confirmDelete = true }
                }
            } else {
                Section("정보") {
                    row("호스트", server.hostName)
                    row("점수", "\(server.score)")
                    row("VPN Gate 측정 핑", server.reportedPing.map { "\($0)ms" } ?? "-")
                    row("가동 시간", server.uptimeText)
                    row("운영자", server.operatorName.isEmpty ? "-" : server.operatorName)
                }
            }

            Section {
                Text("무료 공개 서버는 운영자가 트래픽을 볼 수 있어요. 로그인·결제는 VPN을 끄고 하는 게 안전합니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(server.countryNameKo)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            fileURL = try? store.exportFile(for: server)
        }
        .confirmationDialog("이 설정 파일을 삭제할까요?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("삭제", role: .destructive) {
                store.deleteImported(server)
                dismiss()
            }
        }
    }

    /// 확인은 했는데 응답이 없었던 경우
    private var noResponse: Bool {
        if case .some(.none) = store.measured[server.id] { return true }
        return false
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }
}

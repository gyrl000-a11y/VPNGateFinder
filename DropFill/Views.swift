import SwiftUI
import UIKit

@main
struct DropFillApp: App {
    @Environment(\.scenePhase) private var phase
    @State private var bgTask: UIBackgroundTaskIdentifier = .invalid

    init() {
        UITestMode.prepareSettings()
        if !UITestMode.on {
            Notifier.shared.setup()
            DropAlarm.reschedule()
        }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
            .onChange(of: phase) { p in
                if p == .background {
                    CookieKeeper.save()
                    // 잠깐이라도 더 살아 있도록 (iOS가 약 30초 허용)
                    bgTask = UIApplication.shared.beginBackgroundTask {
                        UIApplication.shared.endBackgroundTask(bgTask)
                        bgTask = .invalid
                    }
                } else if p == .active, bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
            }
    }
}

struct ContentView: View {
    @StateObject private var supreme = BrowserModel(site: .supreme, autoload: !UITestMode.on)
    @StateObject private var palace = BrowserModel(site: .palace, autoload: !UITestMode.on)
    @State private var tab = Site.supreme.rawValue

    var body: some View {
        TabView(selection: $tab) {
            BrowserScreen(model: supreme)
                .tabItem { Label("Supreme", systemImage: "s.square.fill") }
                .badge(supreme.gate == .none ? nil : Text("!"))
                .tag(Site.supreme.rawValue)
            BrowserScreen(model: palace)
                .tabItem { Label("Palace", systemImage: "triangle") }
                .badge(palace.gate == .none ? nil : Text("!"))
                .tag(Site.palace.rawValue)
            SettingsView()
                .tabItem { Label("설정", systemImage: "gearshape") }
                .tag("settings")
        }
        .onReceive(NotificationCenter.default.publisher(for: .dropFillFocus)) { n in
            if let site = n.object as? String { tab = site }
        }
        .onAppear {
            if UITestMode.on { UITestMode.loadFixture(into: supreme) }
        }
    }
}

struct WebContainer: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct BrowserScreen: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        VStack(spacing: 0) {
            if let banner = model.gate.banner {
                VStack(spacing: 2) {
                    Text(banner).font(.footnote.weight(.bold))
                    if !model.gateInfo.isEmpty {
                        Text(model.gateInfo).font(.caption.monospacedDigit())
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(model.gate == .captcha ? Color.red : Color.orange)
            }
            ZStack(alignment: .top) {
                WebContainer(view: model.container)
                if model.isLoading {
                    ProgressView(value: model.progress)
                        .progressViewStyle(.linear)
                        .tint(.red)
                }
                if let t = model.toast {
                    Text(t)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 10)
                        .transition(.opacity)
                }
            }
            Divider()
            HStack {
                bar("chevron.left", enabled: model.canGoBack) { model.guarded("뒤로 가기") { model.goBack() } }
                bar("chevron.right", enabled: model.canGoForward) { model.guarded("앞으로 가기") { model.goForward() } }
                bar("arrow.clockwise") { model.guarded("새로고침") { model.reload() } }
                bar("house") { model.guarded("홈으로 이동") { model.goHome() } }
                bar("cart") { model.guarded("장바구니로 이동") { model.openCart() } }
                Button {
                    settings.autoCheckoutOn.toggle()
                    model.showToast(settings.autoCheckoutOn ? "자동 진행 켬" : "자동 진행 끔")
                } label: {
                    Image(systemName: settings.autoCheckoutOn ? "bolt.fill" : "bolt.slash")
                        .foregroundStyle(settings.autoCheckoutOn ? Color.orange : Color.secondary)
                        .frame(maxWidth: .infinity)
                }
                bar("wand.and.stars") { model.refill() }
            }
            .font(.system(size: 18))
            .frame(height: 44)
            .padding(.horizontal, 6)
        }
    }

    private func bar(_ icon: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(maxWidth: .infinity)
        }
        .disabled(!enabled)
    }
}

struct SettingsView: View {
    @ObservedObject private var s = SettingsStore.shared

    private let regions = ["서울특별시", "부산광역시", "대구광역시", "인천광역시", "광주광역시", "대전광역시",
                           "울산광역시", "세종특별자치시", "경기도", "강원특별자치도", "충청북도", "충청남도",
                           "전북특별자치도", "전라남도", "경상북도", "경상남도", "제주특별자치도"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("자동입력", isOn: $s.autofillOn)
                    Toggle("담기 → 체크아웃 자동 진행", isOn: $s.autoCheckoutOn)
                    Toggle("다시 열면 마지막 페이지에서 시작", isOn: $s.resumeLastPage)
                } footer: {
                    Text("최종 결제 버튼은 절대 누르지 않아요. 빨간 테두리로 표시만 합니다. 대기열·캡차가 뜨면 진동과 알림으로 알려 주고, 그동안 화면이 꺼지지 않아요.")
                }

                Section("연락처") {
                    field("이메일", $s.profile.email, "예: name@example.com", .emailAddress, id: "email")
                    field("휴대폰", $s.profile.phone, "010-0000-0000", .phonePad, id: "phone")
                }

                Section {
                    field("성", $s.profile.lastName, "예: 홍", id: "lastName")
                    field("이름", $s.profile.firstName, "예: 길동", id: "firstName")
                    field("우편번호", $s.profile.postal, "예: 21300", .numberPad, id: "postal")
                    Picker("시/도", selection: $s.profile.province) {
                        Text("선택").tag("")
                        ForEach(regions, id: \.self) { Text($0).tag($0) }
                    }
                    field("시/군/구", $s.profile.city, "예: 부평구", id: "city")
                    field("도로명 주소", $s.profile.address1, "예: 산곡로 1", id: "address1")
                    field("상세주소", $s.profile.address2, "예: 101동 1001호", id: "address2")
                } header: {
                    Text("배송지")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if !addressPreview.isEmpty {
                            Text("입력된 주소: \(addressPreview)")
                                .foregroundStyle(.primary)
                                .accessibilityIdentifier("addressPreview")
                        }
                        Text("입력하는 즉시 저장돼요. 상세주소는 동·호수까지 적어 두면 체크아웃의 '아파트, 동, 호수' 칸에 들어가요.")
                    }
                }

                Section {
                    field("카드 번호", $s.card.number, "0000 0000 0000 0000", .numberPad, id: "ccNumber")
                    field("소유자 (영문)", $s.card.name, "HONG GILDONG", id: "ccName")
                    field("유효기간 월", $s.card.month, "MM", .numberPad, id: "ccMonth")
                    field("유효기간 연도", $s.card.year, "YY", .numberPad, id: "ccYear")
                    LabeledContent("CVC") {
                        SecureField("000", text: $s.card.cvc)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("field.ccCsc")
                    }
                } header: {
                    Text("카드")
                } footer: {
                    Text(s.cardInKeychain
                         ? "카드 정보는 이 기기 키체인에만 저장돼요. 결제 화면의 카드 입력칸(Shopify 등)에만 채워집니다."
                         : "키체인 저장이 안 돼서 앱 내부 저장소에 보관 중이에요.")
                }

                Section {
                    Toggle("대기 중 백그라운드 유지", isOn: $s.keepAliveInQueue)
                } header: {
                    Text("대기열")
                } footer: {
                    Text("켜면 대기열·캡차 화면에 있을 때만 무음 오디오로 앱을 깨워 둬서, 다른 앱을 써도 통과 알림을 받을 가능성이 높아져요. 배터리를 더 쓰고, 다른 음악 재생엔 영향 없어요. 대기 중 뒤로·새로고침·홈을 누르면 한 번 확인해요.")
                }

                Section {
                    alarmRow("Supreme", $s.supremeAlarm)
                    alarmRow("Palace", $s.palaceAlarm)
                } header: {
                    Text("드랍 시간 알림")
                } footer: {
                    Text("매주 정해진 요일·시간 5분 전과 1분 전에 알려 줘요. 발매 시간은 공지를 보고 맞춰 주세요.")
                }

                Section {
                    field("Supreme 홈", $s.supremeHome, Site.supreme.defaultHome, .URL, id: "supremeHome")
                    field("Palace 홈", $s.palaceHome, Site.palace.defaultHome, .URL, id: "palaceHome")
                    field("카드 허용 도메인", $s.extraCardHosts, "쉼표로 구분", .URL, id: "extraCardHosts")
                } header: {
                    Text("사이트")
                } footer: {
                    Text("결제창이 다른 결제사 도메인이면 여기에 도메인을 넣어야 카드가 채워져요. 예: pay.example.com")
                }
            }
            .navigationTitle("드랍필 설정")
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("완료") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }
        }
    }

    private static let weekdays = ["일", "월", "화", "수", "목", "금", "토"]

    @ViewBuilder
    private func alarmRow(_ name: String, _ a: Binding<DropAlarmSetting>) -> some View {
        Toggle(name, isOn: a.enabled)
        if a.wrappedValue.enabled {
            Picker("요일", selection: a.weekday) {
                ForEach(1...7, id: \.self) { Text(Self.weekdays[$0 - 1] + "요일").tag($0) }
            }
            DatePicker("시간", selection: Binding(
                get: {
                    Calendar.current.date(bySettingHour: a.wrappedValue.minutes / 60,
                                          minute: a.wrappedValue.minutes % 60, second: 0, of: Date()) ?? Date()
                },
                set: { d in
                    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                    a.wrappedValue.minutes = (c.hour ?? 11) * 60 + (c.minute ?? 0)
                }
            ), displayedComponents: .hourAndMinute)
        }
    }

    private var addressPreview: String {
        let p = s.profile
        return [p.postal, p.province, p.city, p.address1].filter { !$0.isEmpty }.joined(separator: " ")
            + (p.address2.isEmpty ? "" : ", " + p.address2)
    }

    /// 왼쪽에 칸 이름이 항상 보이고, 오른쪽에 입력
    private func field(_ title: String, _ text: Binding<String>, _ placeholder: String = "",
                       _ kb: UIKeyboardType = .default, id: String) -> some View {
        LabeledContent(title) {
            TextField(placeholder, text: text)
                .keyboardType(kb)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier("field.\(id)")
        }
    }
}

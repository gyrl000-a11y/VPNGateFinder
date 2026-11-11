import SwiftUI
import UIKit

@main
struct DropFillApp: App {
    @Environment(\.scenePhase) private var phase
    @State private var bgTask: UIBackgroundTaskIdentifier = .invalid

    init() {
        Notifier.shared.setup()
        DropAlarm.reschedule()
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
    @StateObject private var supreme = BrowserModel(site: .supreme)
    @StateObject private var palace = BrowserModel(site: .palace)
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
                    field("이메일", $s.profile.email, .emailAddress)
                    field("휴대폰 (010-0000-0000)", $s.profile.phone, .phonePad)
                }

                Section("배송지") {
                    field("성", $s.profile.lastName)
                    field("이름", $s.profile.firstName)
                    field("우편번호", $s.profile.postal, .numberPad)
                    Picker("시/도", selection: $s.profile.province) {
                        Text("선택").tag("")
                        ForEach(regions, id: \.self) { Text($0).tag($0) }
                    }
                    field("시/군/구 (예: 부평구)", $s.profile.city)
                    field("주소 (도로명)", $s.profile.address1)
                    field("상세주소 (동·호수)", $s.profile.address2)
                }

                Section {
                    field("카드 번호", $s.card.number, .numberPad)
                    field("카드 소유자 이름 (영문)", $s.card.name)
                    HStack {
                        field("MM", $s.card.month, .numberPad)
                        field("YY", $s.card.year, .numberPad)
                        SecureField("CVC", text: $s.card.cvc).keyboardType(.numberPad)
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
                    field("Supreme 홈", $s.supremeHome, .URL)
                    field("Palace 홈", $s.palaceHome, .URL)
                    field("카드 입력 허용 도메인 추가 (쉼표 구분)", $s.extraCardHosts, .URL)
                } header: {
                    Text("사이트")
                } footer: {
                    Text("결제창이 다른 결제사 도메인이면 여기에 도메인을 넣어야 카드가 채워져요. 예: pay.example.com")
                }
            }
            .navigationTitle("드랍필 설정")
            .scrollDismissesKeyboard(.interactively)
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

    private func field(_ title: String, _ text: Binding<String>, _ kb: UIKeyboardType = .default) -> some View {
        TextField(title, text: text)
            .keyboardType(kb)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }
}

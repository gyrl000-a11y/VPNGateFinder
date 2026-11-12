import Foundation
import Security

struct Profile: Codable, Equatable {
    var email = ""
    var phone = ""
    var lastName = ""
    var firstName = ""
    var postal = ""
    var province = ""
    var city = ""
    var address1 = ""
    var address2 = ""
    // 영문 배송지 (영문 주소를 받는 사이트용)
    var lastNameEn = ""
    var firstNameEn = ""
    var cityEn = ""
    var address1En = ""
    var address2En = ""

    init(email: String = "", phone: String = "", lastName: String = "", firstName: String = "",
         postal: String = "", province: String = "", city: String = "", address1: String = "", address2: String = "",
         lastNameEn: String = "", firstNameEn: String = "", cityEn: String = "",
         address1En: String = "", address2En: String = "") {
        self.email = email; self.phone = phone; self.lastName = lastName; self.firstName = firstName
        self.postal = postal; self.province = province; self.city = city
        self.address1 = address1; self.address2 = address2
        self.lastNameEn = lastNameEn; self.firstNameEn = firstNameEn; self.cityEn = cityEn
        self.address1En = address1En; self.address2En = address2En
    }

    // 예전 버전에 저장된 값(영문 칸 없음)도 그대로 읽히도록
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v(_ k: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? "" }
        self.init(email: v(.email), phone: v(.phone), lastName: v(.lastName), firstName: v(.firstName),
                  postal: v(.postal), province: v(.province), city: v(.city),
                  address1: v(.address1), address2: v(.address2),
                  lastNameEn: v(.lastNameEn), firstNameEn: v(.firstNameEn), cityEn: v(.cityEn),
                  address1En: v(.address1En), address2En: v(.address2En))
    }

    var provinceEn: String { KoreanRegion.english[province] ?? province }

    func dict(_ lang: AddressLang) -> [String: Any] {
        let en = lang == .en
        let last = en ? lastNameEn : lastName
        let first = en ? firstNameEn : firstName
        return ["lang": lang.rawValue, "email": email, "phone": phone,
                "lastName": last, "firstName": first,
                "fullName": en ? "\(first) \(last)" : last + first,
                "postal": postal,
                "province": en ? provinceEn : province,
                "provinceKo": province,
                "city": en ? cityEn : city,
                "address1": en ? address1En : address1,
                "address2": en ? address2En : address2]
    }

    /// 한글 배송지로 영문 칸 채우기 (자동 변환 — 확인 필요)
    mutating func fillEnglishFromKorean() {
        if !lastName.isEmpty { lastNameEn = Romanizer.surname(lastName) }
        if !firstName.isEmpty { firstNameEn = Romanizer.givenName(firstName) }
        if !city.isEmpty { cityEn = Romanizer.city(city) }
        if !address1.isEmpty { address1En = Romanizer.road(address1) }
        if !address2.isEmpty { address2En = Romanizer.detail(address2) }
    }

    var englishMissing: Bool {
        lastNameEn.isEmpty || firstNameEn.isEmpty || cityEn.isEmpty || address1En.isEmpty
    }
}

struct CardInfo: Codable, Equatable {
    var number = ""
    var name = ""
    var month = ""
    var year = ""
    var cvc = ""

    var isEmpty: Bool { number.filter(\.isNumber).isEmpty }
    var dict: [String: Any] { ["number": number, "name": name, "month": month, "year": year, "cvc": cvc] }
}

/// 매주 드랍 알림: weekday 1=일 … 7=토, minutes = 자정부터 분
struct DropAlarmSetting: Codable, Equatable {
    var enabled = false
    var weekday = 7
    var minutes = 11 * 60
}

enum Site: String, CaseIterable, Identifiable {
    case supreme, palace
    var id: String { rawValue }
    var title: String { self == .supreme ? "Supreme KR" : "Palace KR" }
    var defaultHome: String {
        switch self {
        case .supreme: return "https://kr.supreme.com"
        case .palace: return "https://shop-kr.palaceskateboards.com"
        }
    }
}

enum Keychain {
    private static let service = "dropfill"

    @discardableResult
    static func save(_ data: Data, key: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func load(key: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
}

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    private let ud = UserDefaults.standard

    @Published var profile: Profile { didSet { saveJSON(profile, "profile") } }
    @Published var card: CardInfo { didSet { saveCard() } }
    @Published var autofillOn: Bool { didSet { ud.set(autofillOn, forKey: "autofillOn") } }
    @Published var autoCheckoutOn: Bool { didSet { ud.set(autoCheckoutOn, forKey: "autoCheckoutOn") } }
    @Published var supremeHome: String { didSet { ud.set(supremeHome, forKey: "home.supreme") } }
    @Published var palaceHome: String { didSet { ud.set(palaceHome, forKey: "home.palace") } }
    @Published var extraCardHosts: String { didSet { ud.set(extraCardHosts, forKey: "extraCardHosts") } }
    @Published var supremeLang: AddressLang { didSet { ud.set(supremeLang.rawValue, forKey: "lang.supreme") } }
    @Published var palaceLang: AddressLang { didSet { ud.set(palaceLang.rawValue, forKey: "lang.palace") } }
    @Published var resumeLastPage: Bool { didSet { ud.set(resumeLastPage, forKey: "resumeLastPage") } }
    @Published var keepAliveInQueue: Bool { didSet { ud.set(keepAliveInQueue, forKey: "keepAliveInQueue") } }
    @Published var supremeAlarm: DropAlarmSetting { didSet { saveJSON(supremeAlarm, "alarm.supreme"); DropAlarm.reschedule() } }
    @Published var palaceAlarm: DropAlarmSetting { didSet { saveJSON(palaceAlarm, "alarm.palace"); DropAlarm.reschedule() } }
    @Published private(set) var cardInKeychain = true

    private init() {
        profile = SettingsStore.loadJSON(Profile.self, "profile") ?? Profile()
        if let d = Keychain.load(key: "card"), let c = try? JSONDecoder().decode(CardInfo.self, from: d) {
            card = c
        } else {
            card = SettingsStore.loadJSON(CardInfo.self, "card.fallback") ?? CardInfo()
        }
        let d = UserDefaults.standard
        autofillOn = d.object(forKey: "autofillOn") as? Bool ?? true
        autoCheckoutOn = d.object(forKey: "autoCheckoutOn") as? Bool ?? true
        supremeHome = d.string(forKey: "home.supreme") ?? Site.supreme.defaultHome
        palaceHome = d.string(forKey: "home.palace") ?? Site.palace.defaultHome
        extraCardHosts = d.string(forKey: "extraCardHosts") ?? ""
        supremeLang = AddressLang(rawValue: d.string(forKey: "lang.supreme") ?? "") ?? .en
        palaceLang = AddressLang(rawValue: d.string(forKey: "lang.palace") ?? "") ?? .ko
        resumeLastPage = d.object(forKey: "resumeLastPage") as? Bool ?? true
        keepAliveInQueue = d.object(forKey: "keepAliveInQueue") as? Bool ?? false
        supremeAlarm = SettingsStore.loadJSON(DropAlarmSetting.self, "alarm.supreme") ?? DropAlarmSetting(weekday: 7)
        palaceAlarm = SettingsStore.loadJSON(DropAlarmSetting.self, "alarm.palace") ?? DropAlarmSetting(weekday: 6)
    }

    func lang(for site: Site) -> AddressLang { site == .supreme ? supremeLang : palaceLang }

    func alarm(for site: Site) -> DropAlarmSetting { site == .supreme ? supremeAlarm : palaceAlarm }

    func home(for site: Site) -> URL {
        let s = (site == .supreme ? supremeHome : palaceHome).trimmingCharacters(in: .whitespaces)
        let fixed = s.hasPrefix("http") ? s : "https://" + s
        return URL(string: fixed) ?? URL(string: site.defaultHome)!
    }

    // MARK: host rules

    private static let shopSuffixes = ["supreme.com", "palaceskateboards.com", "myshopify.com", "shopify.com"]
    private static let cardSuffixes = ["shopifyinc.com", "shopifycs.com", "stripe.com", "adyen.com", "braintreegateway.com"]

    private static func match(_ host: String, _ list: [String]) -> Bool {
        let h = host.lowercased()
        return list.contains { raw in
            let suffix = raw.lowercased().trimmingCharacters(in: .whitespaces)
            return !suffix.isEmpty && (h == suffix || h.hasSuffix("." + suffix))
        }
    }

    func isShopHost(_ host: String) -> Bool {
        let homes = Site.allCases.compactMap { home(for: $0).host }
        return Self.match(host, Self.shopSuffixes + homes)
    }

    func isCardHost(_ host: String) -> Bool {
        let extra = extraCardHosts.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init)
        return Self.match(host, Self.cardSuffixes + extra)
    }

    /// 프레임 출처(host)에 따라 넘겨줄 정보를 고른다. 쇼핑몰 도메인엔 주소, 결제 도메인엔 카드만.
    /// site: 요청이 온 탭 — 그 사이트에 맞는 언어(한글/영문)의 배송지를 넘긴다
    func config(forHost host: String, site: Site = .supreme) -> [String: Any] {
        guard autofillOn, !host.isEmpty else { return ["enabled": false] }
        var d: [String: Any] = ["enabled": true, "autoCheckout": autoCheckoutOn]
        let shop = isShopHost(host)
        if shop { d["address"] = profile.dict(lang(for: site)) }
        if (shop || isCardHost(host)) && !card.isEmpty { d["card"] = card.dict }
        if d["address"] == nil && d["card"] == nil { d["enabled"] = false }
        return d
    }

    // MARK: persistence

    private func saveCard() {
        guard let data = try? JSONEncoder().encode(card) else { return }
        if Keychain.save(data, key: "card") {
            ud.removeObject(forKey: "card.fallback")
            if !cardInKeychain { cardInKeychain = true }
        } else {
            saveJSON(card, "card.fallback")
            if cardInKeychain { cardInKeychain = false }
        }
    }

    private func saveJSON<T: Encodable>(_ v: T, _ key: String) {
        if let d = try? JSONEncoder().encode(v) { ud.set(d, forKey: key) }
    }

    private static func loadJSON<T: Decodable>(_ t: T.Type, _ key: String) -> T? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(t, from: d)
    }
}

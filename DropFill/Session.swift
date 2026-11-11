import AVFoundation
import AudioToolbox
import Foundation
import UIKit
import UserNotifications
import WebKit

enum Gate: String {
    case none, queue, captcha

    var banner: String? {
        switch self {
        case .none: return nil
        case .queue: return "대기열 대기 중 · 앱을 켜 둔 채로 기다려 주세요"
        case .captcha: return "캡차가 떴어요 · 직접 풀어 주세요"
        }
    }
}

extension Notification.Name {
    /// object: Site.rawValue — 해당 탭으로 전환
    static let dropFillFocus = Notification.Name("dropFillFocus")
}

// MARK: - 알림 (진동 + 로컬 알림)

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    func setup() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func notify(_ title: String, _ body: String, haptic: UINotificationFeedbackGenerator.FeedbackType, site: Site? = nil) {
        let gen = UINotificationFeedbackGenerator()
        gen.notificationOccurred(haptic)
        if haptic != .success {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        if let site { content.userInfo = ["site": site.rawValue] }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // 앱이 켜져 있어도 배너·소리 표시
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // 알림을 누르면 해당 탭으로
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let site = response.notification.request.content.userInfo["site"] as? String {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .dropFillFocus, object: site)
            }
        }
        completionHandler()
    }
}

// MARK: - 드랍 시간 알림 (5분 전·1분 전, 매주 반복)

enum DropAlarm {
    static func reschedule() {
        let c = UNUserNotificationCenter.current()
        let ids = Site.allCases.flatMap { site in [5, 1].map { "drop.\(site.rawValue).\($0)" } }
        c.removePendingNotificationRequests(withIdentifiers: ids)
        let s = SettingsStore.shared
        for site in Site.allCases {
            let a = s.alarm(for: site)
            guard a.enabled else { continue }
            for before in [5, 1] {
                // 요일(1=일 … 7=토) + 분 단위로 계산해 하루 넘김 처리
                var total = (a.weekday - 1) * 1440 + a.minutes - before
                total = (total + 7 * 1440) % (7 * 1440)
                var dc = DateComponents()
                dc.weekday = total / 1440 + 1
                dc.hour = (total % 1440) / 60
                dc.minute = total % 60
                let content = UNMutableNotificationContent()
                content.title = "\(site.title) 드랍 \(before)분 전"
                content.body = before == 5 ? "로그인 상태와 배송지·카드 정보를 확인하세요." : "곧 시작해요. 앱을 열어 두세요."
                content.sound = .default
                content.interruptionLevel = .timeSensitive
                content.userInfo = ["site": site.rawValue]
                let trig = UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)
                c.add(UNNotificationRequest(identifier: "drop.\(site.rawValue).\(before)", content: content, trigger: trig))
            }
        }
    }
}

// MARK: - 대기열 중 백그라운드 유지 (무음 오디오, 선택)

enum KeepAlive {
    private static var player: AVAudioPlayer?

    static func update(active: Bool) {
        if active && SettingsStore.shared.keepAliveInQueue { start() } else { stop() }
    }

    private static func start() {
        guard player == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            let p = try AVAudioPlayer(data: silentWAV())
            p.numberOfLoops = -1
            p.volume = 0
            p.play()
            player = p
        } catch {
            player = nil
        }
    }

    private static func stop() {
        guard let p = player else { return }
        p.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 1초짜리 무음 WAV (8kHz, 16bit, mono)
    private static func silentWAV() -> Data {
        let rate: UInt32 = 8000, samples: UInt32 = 8000
        let dataSize = samples * 2
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(36 + dataSize)
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(dataSize)
        d.append(Data(count: Int(dataSize)))
        return d
    }
}

// MARK: - 대기열 중 화면 꺼짐 방지

enum GateCenter {
    private static var active = Set<String>()
    private static var saver: Timer?

    static var isActive: Bool { !active.isEmpty }

    static func set(_ site: Site, gate: Gate) {
        if gate == .none { active.remove(site.rawValue) } else { active.insert(site.rawValue) }
        let on = !active.isEmpty
        UIApplication.shared.isIdleTimerDisabled = on
        KeepAlive.update(active: on)
        // 대기 중엔 20초마다 세션 쿠키 저장 (앱이 갑자기 종료돼도 순번 쿠키 보존)
        if on, saver == nil {
            saver = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in CookieKeeper.save() }
        } else if !on {
            saver?.invalidate()
            saver = nil
        }
    }
}

// MARK: - 세션 쿠키 보존

/// WKWebView는 앱이 종료되면 만료일 없는 세션 쿠키(로그인·대기열 순번 등)를 버린다.
/// 백그라운드로 갈 때 키체인에 저장해 두고, 다음 실행 때 페이지를 열기 전에 되살린다.
enum CookieKeeper {
    private static let key = "sessionCookies"
    private static var restored = false
    private static var restoring = false
    private static var waiters: [() -> Void] = []

    private static var store: WKHTTPCookieStore { WKWebsiteDataStore.default().httpCookieStore }

    static func save() {
        store.getAllCookies { cookies in
            let list: [[String: Any]] = cookies.filter { $0.expiresDate == nil }.compactMap { c in
                guard var props = c.properties else { return nil }
                props.removeValue(forKey: .port)  // 배열 값은 plist 변환에서 제외
                var out: [String: Any] = [:]
                for (k, v) in props {
                    if v is String || v is Date || v is NSNumber { out[k.rawValue] = v }
                    else if let u = v as? URL { out[k.rawValue] = u.absoluteString }
                }
                return out
            }
            guard let data = try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
            else { return }
            Keychain.save(data, key: key)
        }
    }

    /// 저장된 세션 쿠키를 복원한 뒤 then 실행 (여러 탭이 불러도 한 번만 복원)
    static func restore(then: @escaping () -> Void) {
        if restored { then(); return }
        waiters.append(then)
        if restoring { return }
        restoring = true

        let list: [[String: Any]]
        if let data = Keychain.load(key: key),
           let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] {
            list = obj
        } else {
            list = []
        }
        let cookies = list.compactMap { dict -> HTTPCookie? in
            var props: [HTTPCookiePropertyKey: Any] = [:]
            for (k, v) in dict { props[HTTPCookiePropertyKey(k)] = v }
            return HTTPCookie(properties: props)
        }

        let group = DispatchGroup()
        for c in cookies {
            group.enter()
            store.setCookie(c) { group.leave() }
        }
        group.notify(queue: .main) {
            restored = true
            restoring = false
            let w = waiters
            waiters = []
            w.forEach { $0() }
        }
    }
}

// MARK: - 마지막 페이지

enum LastPage {
    static func save(_ url: URL?, site: Site) {
        guard let url, let s = url.scheme, s.hasPrefix("http") else { return }
        UserDefaults.standard.set(url.absoluteString, forKey: "last.\(site.rawValue)")
    }

    static func load(site: Site) -> URL? {
        UserDefaults.standard.string(forKey: "last.\(site.rawValue)").flatMap(URL.init(string:))
    }
}

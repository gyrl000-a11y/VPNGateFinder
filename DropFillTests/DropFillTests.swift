import UIKit
import WebKit
import XCTest
@testable import DropFill

/// 실제 WebKit(시뮬레이터)에서 스크립트가 동작하는지 확인한다.
/// loadHTMLString(baseURL:)로 출처(host)를 흉내 내서 주소/카드 허용 규칙까지 함께 검증.
@MainActor
final class DropFillTests: XCTestCase {
    private var window: UIWindow?

    private func configure() {
        let s = SettingsStore.shared
        s.autofillOn = true
        s.autoCheckoutOn = true
        s.profile = Profile(email: "a@b.com", phone: "010-1234-5678", lastName: "김", firstName: "혁",
                            postal: "21300", province: "인천광역시", city: "부평구",
                            address1: "산곡로 1", address2: "101동 1001호")
        s.card = CardInfo(number: "4111 1111 1111 1111", name: "HYUK KIM", month: "7", year: "2029", cvc: "123")
    }

    private func makeModel() -> BrowserModel {
        configure()
        window?.isHidden = true
        let m = BrowserModel(site: .supreme, autoload: false)
        let vc = UIViewController()
        vc.view = m.container
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = vc
        w.makeKeyAndVisible()
        window = w
        return m
    }

    private func load(_ m: BrowserModel, _ html: String, _ url: String) {
        m.webView.loadHTMLString(html, baseURL: URL(string: url)!)
    }

    private func js(_ m: BrowserModel, _ code: String) async -> Any? {
        try? await m.webView.evaluateJavaScript(code)
    }

    private func value(_ m: BrowserModel, _ name: String) async -> String {
        (await js(m, "(document.querySelector('[name=\"\(name)\"]')||{}).value || ''") as? String) ?? ""
    }

    private func wait(_ timeout: TimeInterval = 12, _ cond: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    static let checkoutFields = """
    <label for="em">이메일</label><input id="em" name="email" autocomplete="email">
    <select name="countryCode" autocomplete="shipping country">
      <option value="US">미국</option><option value="KP">조선민주주의인민공화국</option><option value="KR">대한민국</option>
    </select>
    <input name="lastName" autocomplete="shipping family-name">
    <input name="firstName" autocomplete="shipping given-name">
    <input name="postalCode" autocomplete="shipping postal-code">
    <select name="zone" autocomplete="shipping address-level1">
      <option value="">시/도</option><option value="KR-11">서울특별시</option>
      <option value="KR-28">인천광역시</option><option value="KR-41">경기도</option>
    </select>
    <input name="city" autocomplete="shipping address-level2">
    <input name="address1" autocomplete="shipping address-line1">
    <input name="address2" autocomplete="shipping address-line2">
    <input name="phone" autocomplete="shipping tel">
    <label for="dc">할인 코드 또는 기프트 카드</label><input id="dc" name="reductions">
    """

    // 1. 체크아웃: 주소 채움 + 결제 버튼 표시만, 클릭 안 함
    func testCheckoutAutofillStopsBeforePay() async {
        let m = makeModel()
        let html = "<html><body>\(Self.checkoutFields)<button id='pay' onclick='window.__paid=true'>지금 결제</button></body></html>"
        load(m, html, "https://kr.supreme.com/checkouts/cn/test")

        let ok = await wait { await self.value(m, "address2") == "101동 1001호" }
        XCTAssertTrue(ok, "address2 not filled")
        let country = await value(m, "countryCode")
        let zone = await value(m, "zone")
        let last = await value(m, "lastName")
        let phone = await value(m, "phone")
        let disc = await value(m, "reductions")
        XCTAssertEqual(country, "KR")
        XCTAssertEqual(zone, "KR-28")
        XCTAssertEqual(last, "김")
        XCTAssertEqual(phone, "010-1234-5678")
        XCTAssertEqual(disc, "", "discount field must stay empty")

        let marked = await wait(5) {
            ((await self.js(m, "document.getElementById('pay').style.outline") as? String) ?? "").contains("3px")
        }
        XCTAssertTrue(marked, "pay button not highlighted")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let paid = await js(m, "window.__paid === true") as? Bool
        XCTAssertEqual(paid, false, "pay button must never be clicked")
    }

    // 2. 다단계 체크아웃: '배송으로 계속'은 자동 클릭
    func testContinueButtonClicked() async {
        let m = makeModel()
        let html = "<html><body>\(Self.checkoutFields)<button onclick='window.__cont=true'>배송으로 계속</button></body></html>"
        load(m, html, "https://shop-kr.palaceskateboards.com/checkouts/abc?step=contact_information")
        let ok = await wait { (await self.js(m, "window.__cont === true") as? Bool) == true }
        XCTAssertTrue(ok, "continue not clicked")
    }

    // 3. 카드 입력 도메인: 카드만 채움
    func testCardFrameHost() async {
        let m = makeModel()
        let html = """
        <html><body><input name="number" autocomplete="cc-number"><input name="expiry" autocomplete="cc-exp">
        <input name="verification_value" autocomplete="cc-csc"><input name="name"></body></html>
        """
        load(m, html, "https://checkout.pci.shopifyinc.com/build/test/number-ltr.html")
        let ok = await wait { await self.value(m, "number") == "4111111111111111" }
        XCTAssertTrue(ok, "card number not filled")
        let exp = await value(m, "expiry")
        let cvc = await value(m, "verification_value")
        let name = await value(m, "name")
        XCTAssertEqual(exp, "07 / 29")
        XCTAssertEqual(cvc, "123")
        XCTAssertEqual(name, "HYUK KIM")
    }

    // 4. 모르는 사이트: 아무것도 안 채움
    func testUnknownHostNotFilled() async {
        let m = makeModel()
        load(m, "<html><body>\(Self.checkoutFields)</body></html>", "https://example.com/checkout")
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let email = await value(m, "email")
        XCTAssertEqual(email, "", "must not fill on unknown host")
    }

    // 5. 대기열 감지 → 통과 감지, 대기 순번 표시
    func testQueueDetectionAndPass() async {
        let m = makeModel()
        let q = "<html><head><title>Queue</title></head><body><h1>You're in line to check out</h1><p>앞에 1,234명 · 예상 대기 시간 5분</p></body></html>"
        load(m, q, "https://kr.supreme.com/throttle/queue")
        let inQueue = await wait { m.gate == .queue }
        XCTAssertTrue(inQueue, "queue not detected")
        let info = await wait(5) { m.gateInfo.contains("1,234") }
        XCTAssertTrue(info, "queue info not parsed: \(m.gateInfo)")
        XCTAssertFalse(m.webView.allowsBackForwardNavigationGestures, "swipe-back should be off in queue")

        load(m, "<html><body>\(Self.checkoutFields)</body></html>", "https://kr.supreme.com/checkouts/cn/after")
        let passed = await wait { m.gate == .none }
        XCTAssertTrue(passed, "queue pass not detected")
        let filled = await wait { await self.value(m, "lastName") == "김" }
        XCTAssertTrue(filled, "autofill should continue after queue")
    }

    // 6. 캡차 감지 (보이지 않는 reCAPTCHA는 무시)
    func testCaptchaDetection() async {
        let m = makeModel()
        load(m, "<html><body><h1>상품</h1><iframe src='https://www.google.com/recaptcha/api2/anchor?size=invisible' width='256' height='60'></iframe></body></html>",
             "https://kr.supreme.com/products/x")
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(m.gate, .none, "invisible recaptcha must be ignored")

        load(m, "<html><body><div class='h-captcha' style='width:300px;height:80px'></div></body></html>",
             "https://kr.supreme.com/challenge")
        let cap = await wait { m.gate == .captcha }
        XCTAssertTrue(cap, "captcha not detected")
    }

    // 7. 설정: 허용 규칙
    func testHostRules() {
        configure()
        let s = SettingsStore.shared
        XCTAssertNotNil(s.config(forHost: "kr.supreme.com")["address"])
        XCTAssertNotNil(s.config(forHost: "checkout.pci.shopifyinc.com")["card"])
        XCTAssertNil(s.config(forHost: "checkout.pci.shopifyinc.com")["address"])
        XCTAssertEqual(s.config(forHost: "evil-supreme.com")["enabled"] as? Bool, false)
        XCTAssertEqual(s.config(forHost: "example.com")["enabled"] as? Bool, false)
    }
}

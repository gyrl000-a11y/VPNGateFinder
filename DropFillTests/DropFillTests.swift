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
        s.supremeLang = .en
        s.palaceLang = .ko
        s.profile = Profile(email: "a@b.com", phone: "010-1234-5678", lastName: "김", firstName: "혁",
                            postal: "21300", province: "인천광역시", city: "부평구",
                            address1: "산곡로 1", address2: "101동 1001호",
                            lastNameEn: "KIM", firstNameEn: "HYUK", cityEn: "Bupyeong-gu",
                            address1En: "1, Sangok-ro", address2En: "101-dong 1001-ho")
        s.card = CardInfo(number: "4111 1111 1111 1111", name: "HYUK KIM", month: "7", year: "2029", cvc: "123",
                          birth: "19900101", customs: "p123456789012", pin2: "12")
        s.autoAgree = true
        s.diagMode = false
    }

    private func makeModel(_ site: Site = .palace) -> BrowserModel {
        configure()
        window?.isHidden = true
        let m = BrowserModel(site: site, autoload: false)
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

    private func wait(_ timeout: TimeInterval = 25, _ cond: () async -> Bool) async -> Bool {
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
        load(m, html, "https://kr.palaceskateboards.com/checkouts/abc?step=contact_information")
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

    // 8. Supreme 탭은 영문 배송지, Palace 탭은 한글 배송지
    func testSupremeGetsEnglishAddress() async {
        let m = makeModel(.supreme)
        load(m, "<html><body>\(Self.checkoutFields)</body></html>", "https://kr.supreme.com/checkouts/cn/en")
        let ok = await wait { await self.value(m, "address1") == "1, Sangok-ro" }
        XCTAssertTrue(ok, "Supreme should get English address1")
        let last = await value(m, "lastName")
        let first = await value(m, "firstName")
        let city = await value(m, "city")
        let a2 = await value(m, "address2")
        let zone = await value(m, "zone")
        XCTAssertEqual(last, "KIM")
        XCTAssertEqual(first, "HYUK")
        XCTAssertEqual(city, "Bupyeong-gu")
        XCTAssertEqual(a2, "101-dong 1001-ho")
        XCTAssertEqual(zone, "KR-28", "province select should still match 인천")
    }

    func testPalaceGetsKoreanAddress() async {
        let m = makeModel(.palace)
        load(m, "<html><body>\(Self.checkoutFields)</body></html>", "https://kr.palaceskateboards.com/checkouts/cn/ko")
        let ok = await wait { await self.value(m, "address1") == "산곡로 1" }
        XCTAssertTrue(ok, "Palace should get Korean address1")
        let last = await value(m, "lastName")
        let a2 = await value(m, "address2")
        XCTAssertEqual(last, "김")
        XCTAssertEqual(a2, "101동 1001호")
    }

    // 9. 영문 시/도 선택칸 (영문 체크아웃)
    func testEnglishProvinceSelect() async {
        let m = makeModel(.supreme)
        let html = """
        <html><body><select name="zone" autocomplete="shipping address-level1">
        <option value="">Province</option><option value="SEOUL">Seoul</option>
        <option value="INCHEON">Incheon</option><option value="GYEONGGI">Gyeonggi</option></select></body></html>
        """
        load(m, html, "https://kr.supreme.com/checkouts/cn/en2")
        let ok = await wait { await self.value(m, "zone") == "INCHEON" }
        XCTAssertTrue(ok, "English province option not matched")
    }

    // 10. 한글 → 영문 자동 변환
    func testRomanizer() {
        XCTAssertEqual(Romanizer.city("부평구"), "Bupyeong-gu")
        XCTAssertEqual(Romanizer.city("수원시 팔달구"), "Paldal-gu, Suwon-si")
        XCTAssertEqual(Romanizer.road("산곡로 1"), "1, Sangok-ro")
        XCTAssertEqual(Romanizer.road("부평대로 283"), "283, Bupyeong-daero")
        XCTAssertEqual(Romanizer.road("산곡로10번길 5"), "5, Sangok-ro 10beon-gil")
        XCTAssertEqual(Romanizer.detail("101동 1001호"), "101-dong 1001-ho")
        XCTAssertEqual(Romanizer.surname("김"), "KIM")
        XCTAssertEqual(Romanizer.givenName("혁"), "HYEOK")
        XCTAssertEqual(Romanizer.romanize("신라"), "silla")
        XCTAssertEqual(Romanizer.romanize("종로"), "jongno")
        XCTAssertEqual(KoreanRegion.english["인천광역시"], "Incheon")

        var p = Profile(lastName: "김", firstName: "혁", province: "인천광역시", city: "부평구",
                        address1: "산곡로 1", address2: "101동 1001호")
        p.fillEnglishFromKorean()
        XCTAssertEqual(p.address1En, "1, Sangok-ro")
        XCTAssertEqual(p.provinceEn, "Incheon")
    }

    // 11. 예전 버전에 저장된 배송지(영문 칸 없음)도 그대로 읽힘
    func testOldProfileStillDecodes() throws {
        let old = #"{"email":"a@b.com","phone":"010","lastName":"김","firstName":"혁","postal":"21300","province":"인천광역시","city":"부평구","address1":"산곡로 1","address2":"101동 1001호"}"#
        let p = try JSONDecoder().decode(Profile.self, from: Data(old.utf8))
        XCTAssertEqual(p.address2, "101동 1001호")
        XCTAssertEqual(p.address1En, "")
    }

    // 12. Supreme 결제 옵션: 생년월일·개인통관고유부호
    func testIdentityFields() async {
        let m = makeModel(.supreme)
        let html = """
        <html><body>
        <label for="b8">생년월일 (8자리)</label><input id="b8" name="birth8" maxlength="8">
        <label for="b6">생년월일 6자리</label><input id="b6" name="custom_b6" maxlength="6">
        <label for="bd">Date of birth</label><input id="bd" name="dob" type="date">
        <label for="pc">개인통관고유부호</label><input id="pc" name="pccc">
        <label for="dc">할인 코드</label><input id="dc" name="reductions">
        </body></html>
        """
        load(m, html, "https://kr.supreme.com/checkouts/cn/id")
        let ok = await wait { await self.value(m, "pccc") == "P123456789012" }
        XCTAssertTrue(ok, "customs code not filled")
        let b8 = await value(m, "birth8")
        let b6 = await value(m, "custom_b6")
        let bd = await value(m, "dob")
        let dc = await value(m, "reductions")
        XCTAssertEqual(b8, "19900101")
        XCTAssertEqual(b6, "900101")
        XCTAssertEqual(bd, "1990-01-01")
        XCTAssertEqual(dc, "")
    }

    // 13. Palace 장바구니: 필수 약관만 체크 → 체크아웃 버튼 자동 클릭
    func testCartAgreeThenCheckout() async {
        let m = makeModel(.palace)
        let html = """
        <html><body>
        <label><input type="checkbox" id="terms"> 이용약관에 동의합니다 TERMS AND CONDITIONS</label>
        <label><input type="checkbox" id="mkt"> 개인정보 수집·이용 및 광고성 정보 수신에 동의합니다</label>
        <input type="email" name="email" id="signup-email" autocomplete="email">
        <button name="checkout" id="co" disabled onclick="window.__co=true">CHECKOUT</button>
        <script>
          // Palace처럼: 클릭하면 내부 상태를 뒤집고, 체크 표시·버튼은 0.15초 뒤에 반영
          var st = false, cb = document.getElementById('terms'), co = document.getElementById('co');
          cb.addEventListener('click', function (e) {
            e.preventDefault(); st = !st;
            setTimeout(function () { cb.checked = st; co.disabled = !st; window.__st = st; }, 150);
          });
        </script>
        </body></html>
        """
        load(m, html, "https://kr.palaceskateboards.com/cart")
        let ok = await wait { (await self.js(m, "window.__co === true") as? Bool) == true }
        XCTAssertTrue(ok, "checkout not clicked after agreeing")
        let terms = await js(m, "document.getElementById('terms').checked") as? Bool
        let mkt = await js(m, "document.getElementById('mkt').checked") as? Bool
        let state = await js(m, "window.__st === true") as? Bool
        let signup = await value(m, "email")
        XCTAssertEqual(terms, true)
        XCTAssertEqual(state, true, "site state must match the checked box")
        XCTAssertEqual(mkt, false, "ad consent must stay unchecked")
        XCTAssertEqual(signup, "", "newsletter signup email must stay empty")
    }

    // 13b. Supreme 체크아웃 결제 옵션 (실제 진단 결과를 본뜬 화면)
    func testSupremeCheckoutOptions() async {
        let m = makeModel(.supreme)
        let html = """
        <html><body>
        <label><input type="checkbox" id="save" name="save_shipping_information"> save this information for next time</label>
        <label><input type="checkbox" id="c0" name="custom-checkbox-0"> I am 14 years or older.</label>
        <label><input type="checkbox" id="c1" name="custom-checkbox-1"> I accept the Global-e terms &amp; conditions</label>
        <label><input type="checkbox" id="c2" name="custom-checkbox-2"> I accept the collection and use of my personal information</label>
        <label><input type="checkbox" id="c3" name="custom-checkbox-3"> Accept all</label>
        <label><input type="checkbox" id="tos" name="accept-tos"> I have read and agree to the Supreme Terms of Use</label>
        <label for="dob">Date of birth (YYYY-MM-DD)</label>
        <input id="dob" name="x-PaymentAdditionalField-Cards-PersonalCardDateOfBirth" autocomplete="on">
        <label for="pin">PIN code first two digits</label>
        <input id="pin" name="x-PaymentAdditionalField-Cards-PersonalCardPinCodeFirstTwoDigits" autocomplete="on">
        <label for="pcc">Personal customs code</label><input id="pcc" name="Personal Customs Code" autocomplete="on">
        <button id="pay" onclick="window.__paid=true">Pay now</button>
        <script>
          // 통관부호 칸: 한 번에 들어온 값은 지우고, 한 글자씩 입력된 것만 받아들임
          var pcc = document.getElementById('pcc'), typed = '';
          pcc.addEventListener('input', function (e) {
            if (e.data && e.data.length === 1) typed += e.data;
            else setTimeout(function () { pcc.value = typed; }, 30);
          });
          ['c0','c1','c2','tos'].forEach(function (id) {
            var cb = document.getElementById(id), st = false;
            cb.addEventListener('click', function (e) { e.preventDefault(); st = !st; setTimeout(function () { cb.checked = st; }, 100); });
          });
        </script></body></html>
        """
        load(m, html, "https://shop.supreme.com/checkouts/cn/test/en-kr")
        let ok = await wait { await self.value(m, "Personal Customs Code") == "P123456789012" }
        XCTAssertTrue(ok, "customs code not accepted")
        let agreed = await wait {
            (await self.js(m, "['c0','c1','c2','tos'].every(function(i){return document.getElementById(i).checked})") as? Bool) == true
        }
        XCTAssertTrue(agreed, "required agreements not checked")
        let untouched = await js(m, "!document.getElementById('c3').checked && !document.getElementById('save').checked") as? Bool
        XCTAssertEqual(untouched, true, "'Accept all' / 'save info' must stay unchecked")
        let dob = await js(m, "document.getElementById('dob').value") as? String
        let pin = await js(m, "document.getElementById('pin').value") as? String
        XCTAssertEqual(dob, "1990-01-01")
        XCTAssertEqual(pin, "12")
        let paid = await js(m, "window.__paid === true") as? Bool
        XCTAssertEqual(paid, false, "pay button must never be clicked")
    }

    // 14. 진단 모드: 모르는 사이트라도 칸 목록을 수집 (입력값은 제외)
    func testDiagnostics() async {
        let m = makeModel(.supreme)          // makeModel이 설정을 초기화하므로 그 뒤에 켬
        SettingsStore.shared.diagMode = true
        defer { SettingsStore.shared.diagMode = false }
        load(m, "<html><body><label for='x'>생년월일</label><input id='x' name='bd' value='secret'><button>결제하기</button></body></html>",
             "https://pay.example.com/form")
        let ok = await wait { !m.diag.isEmpty }
        if !ok {
            let st = try? await m.webView.evaluateJavaScript(
                "String(window.__dfLoaded) + ' | ' + String(window.__dfCfgKeys) + ' | ' + String(window.__dfDiagState)",
                in: nil, contentWorld: .defaultClient)
            XCTFail("diag state: \(String(describing: st)) | diagMode=\(SettingsStore.shared.diagMode)")
        }
        XCTAssertTrue(ok, "no diagnostics collected")
        XCTAssertTrue(m.diagText.contains("name=bd"))
        XCTAssertTrue(m.diagText.contains("key=birth"))
        XCTAssertFalse(m.diagText.contains("secret"), "values must not be included")
    }

    // 15. 업데이트 전 저장된 카드 정보(새 칸 없음)도 그대로 읽힘
    func testOldCardStillDecodes() throws {
        let old = #"{"number":"4111","name":"A","month":"7","year":"29","cvc":"1"}"#
        let c = try JSONDecoder().decode(CardInfo.self, from: Data(old.utf8))
        XCTAssertEqual(c.number, "4111")
        XCTAssertEqual(c.birth, "")
        let a = try JSONDecoder().decode(DropAlarmSetting.self, from: Data(#"{"enabled":true}"#.utf8))
        XCTAssertTrue(a.enabled)
        XCTAssertEqual(a.minutes, 11 * 60)
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

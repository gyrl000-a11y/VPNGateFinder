import Foundation
import WebKit

/// UI 테스트 전용 실행 모드 (실제 사용 시엔 동작하지 않음)
///  -uitest        : 네트워크 대신 체크아웃 모양 테스트 페이지를 Supreme 탭에 띄움, 알림 권한 요청 생략
///  -uitest-reset  : 상세주소를 비운 예시 배송지로 초기화
enum UITestMode {
    static var on: Bool { ProcessInfo.processInfo.arguments.contains("-uitest") }
    /// XCTest가 앱을 띄운 경우 (단위 테스트 포함) — 알림 권한 팝업 등 생략
    static var underTests: Bool { on || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }
    static var reset: Bool { ProcessInfo.processInfo.arguments.contains("-uitest-reset") }

    static func prepareSettings() {
        guard reset else { return }
        let s = SettingsStore.shared
        s.autofillOn = true
        s.autoCheckoutOn = true
        s.resumeLastPage = false
        s.profile = Profile(email: "test@example.com", phone: "010-1234-5678", lastName: "김", firstName: "혁",
                            postal: "21300", province: "인천광역시", city: "부평구",
                            address1: "산곡로 1", address2: "")
    }

    static func loadFixture(into m: BrowserModel) {
        m.webView.loadHTMLString(fixture, baseURL: URL(string: "https://kr.supreme.com/checkouts/cn/uitest")!)
    }

    static let fixture = """
    <!doctype html><html lang="ko"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>체크아웃 테스트</title>
    <style>
      body{font:16px -apple-system,sans-serif;margin:16px;color:#111}
      h2{font-size:18px;margin:18px 0 8px}
      label{display:block;font-size:13px;color:#555;margin:10px 0 4px}
      input,select{width:100%;box-sizing:border-box;font-size:16px;padding:10px;border:1px solid #ccc;border-radius:8px}
      button{width:100%;margin-top:20px;padding:14px;font-size:17px;border:0;border-radius:10px;background:#111;color:#fff}
    </style></head><body>
    <h2>연락처</h2>
    <label for="em">이메일</label><input id="em" name="email" autocomplete="email">
    <h2>배송</h2>
    <label for="cc">국가/지역</label>
    <select id="cc" name="countryCode" autocomplete="shipping country">
      <option value="US">미국</option><option value="KR">대한민국</option></select>
    <label for="ln">성</label><input id="ln" name="lastName" autocomplete="shipping family-name">
    <label for="fn">이름</label><input id="fn" name="firstName" autocomplete="shipping given-name">
    <label for="a1">주소</label><input id="a1" name="address1" autocomplete="shipping address-line1">
    <label for="a2">상세주소</label><input id="a2" name="address2" autocomplete="shipping address-line2">
    <label for="ct">시/군/구</label><input id="ct" name="city" autocomplete="shipping address-level2">
    <label for="zn">시/도</label>
    <select id="zn" name="zone" autocomplete="shipping address-level1">
      <option value="">선택</option><option value="KR-11">서울특별시</option>
      <option value="KR-28">인천광역시</option><option value="KR-41">경기도</option></select>
    <label for="pc">우편번호</label><input id="pc" name="postalCode" autocomplete="shipping postal-code">
    <label for="ph">전화</label><input id="ph" name="phone" autocomplete="shipping tel">
    <button id="pay" onclick="document.title='PAID'">지금 결제</button>
    </body></html>
    """
}

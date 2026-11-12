import XCTest

/// 실제 앱 화면을 손가락으로 조작하듯 테스트한다.
/// 설정 탭에서 상세주소 입력 → 앱 재실행 후에도 남아 있는지 → 체크아웃 화면에 그대로 채워지는지.
final class SettingsUITests: XCTestCase {
    private let detail = "101동 1001호"
    private let detailEn = "101-dong 1001-ho"

    override func setUp() {
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "system alert") { alert in
            for b in ["Allow", "허용", "OK", "확인"] where alert.buttons[b].exists {
                alert.buttons[b].tap(); return true
            }
            return false
        }
    }

    private func shot(_ name: String) {
        let image = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: image)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? image.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }

    private func openTab(_ app: XCUIApplication, _ title: String) {
        let inBar = app.tabBars.buttons[title]
        if inBar.waitForExistence(timeout: 5) { inBar.tap() } else { app.buttons[title].firstMatch.tap() }
    }

    private func reveal(_ el: XCUIElement, in app: XCUIApplication) {
        var n = 0
        while !el.isHittable && n < 8 { app.swipeUp(); n += 1 }
    }

    /// 목록은 화면에 들어올 때 칸이 만들어지므로, 아래로 내리며 찾는다
    private func scrollFind(_ el: XCUIElement, in app: XCUIApplication, _ name: String) -> Bool {
        if el.waitForExistence(timeout: 3) { reveal(el, in: app); return true }
        for _ in 0..<10 {
            app.swipeUp()
            if el.exists { reveal(el, in: app); return true }
        }
        dumpHierarchy(app, name)
        return false
    }

    private func dumpHierarchy(_ app: XCUIApplication, _ name: String) {
        shot("fail-\(name)")
        if let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] {
            try? app.debugDescription.write(toFile: dir + "/fail-\(name).txt", atomically: true, encoding: .utf8)
        }
    }

    /// 한글은 한 번에 빠르게 치면 첫 글자만 남는 경우가 있어 한 글자씩 입력
    private func typeSlowly(_ text: String, into el: XCUIElement) {
        for ch in text {
            el.typeText(String(ch))
            usleep(120_000)
        }
    }

    private func dismissKeyboard(_ app: XCUIApplication) {
        let done = app.buttons["완료"].firstMatch
        if done.exists { done.tap() }
    }

    func testDetailAddressEntryPersistsAndFills() {
        // 1) 깨끗한 상태로 실행 → 설정 탭에서 상세주소 입력
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-uitest-reset"]
        app.launch()
        openTab(app, "설정")

        XCTAssertTrue(app.navigationBars["드랍필 설정"].waitForExistence(timeout: 10), "설정 화면이 안 열림")
        let field = app.textFields["field.address2"]
        XCTAssertTrue(scrollFind(field, in: app, "settings-field"), "설정에 상세주소 칸이 없음")
        XCTAssertTrue(app.staticTexts["상세주소"].exists, "상세주소 칸 이름이 안 보임")
        field.tap()
        typeSlowly(detail, into: field)
        if (field.value as? String) != detail { dumpHierarchy(app, "typing") }
        XCTAssertEqual(field.value as? String, detail)
        dismissKeyboard(app)
        let preview = app.staticTexts["addressPreview"]
        XCTAssertTrue(scrollFind(preview, in: app, "preview"), "주소 미리보기가 없음")
        XCTAssertTrue(preview.label.contains(detail), "입력된 주소 미리보기에 상세주소 없음: \(preview.label)")
        shot("1-settings-entered")

        // 영문 배송지: 한글 배송지로 자동 채우기
        let fillEn = app.buttons["fillEnglish"]
        XCTAssertTrue(scrollFind(fillEn, in: app, "fill-english"), "영문 자동 채우기 버튼 없음")
        fillEn.tap()
        let en2 = app.textFields["field.address2En"]
        XCTAssertTrue(scrollFind(en2, in: app, "address2En"))
        XCTAssertEqual(en2.value as? String, detailEn)
        let en1 = app.textFields["field.address1En"]
        XCTAssertEqual(en1.value as? String, "1, Sangok-ro")
        let enPreview = app.staticTexts["englishPreview"]
        XCTAssertTrue(scrollFind(enPreview, in: app, "english-preview"))
        shot("1b-settings-english")

        // 2) 앱을 완전히 껐다 켜도 남아 있는지
        app.terminate()
        app.launchArguments = ["-uitest"]
        app.launch()
        openTab(app, "설정")
        let again = app.textFields["field.address2"]
        XCTAssertTrue(scrollFind(again, in: app, "relaunch-field"))
        XCTAssertEqual(again.value as? String, detail, "재실행 후 상세주소가 사라짐")
        let againEn = app.textFields["field.address2En"]
        XCTAssertTrue(scrollFind(againEn, in: app, "relaunch-en"))
        XCTAssertEqual(againEn.value as? String, detailEn, "재실행 후 영문 상세주소가 사라짐")
        shot("2-settings-after-relaunch")

        // 3) Supreme 탭: 영문 배송지가 채워지는지
        checkWebDetail(app, tab: "Supreme", expect: detailEn, shotName: "3-supreme-english")
        // 4) Palace 탭: 한글 배송지가 채워지는지
        checkWebDetail(app, tab: "Palace", expect: detail, shotName: "4-palace-korean")
    }

    private func checkWebDetail(_ app: XCUIApplication, tab: String, expect: String, shotName: String) {
        openTab(app, tab)
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 15), "\(tab) 웹 화면이 안 뜸")
        let webDetail = web.textFields["상세주소"]
        if !webDetail.waitForExistence(timeout: 15) { dumpHierarchy(app, "web-\(tab)") }
        XCTAssertTrue(webDetail.exists, "\(tab) 체크아웃 상세주소 칸을 못 찾음")
        let filled = expectation(for: NSPredicate(format: "value == %@", expect), evaluatedWith: webDetail)
        wait(for: [filled], timeout: 20)
        shot(shotName)
        // 결제 버튼은 눌리지 않았어야 함 (누르면 제목이 PAID로 바뀌게 해 둠)
        XCTAssertFalse(web.staticTexts["PAID"].exists)
    }
}

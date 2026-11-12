import XCTest

/// 실제 앱 화면을 손가락으로 조작하듯 테스트한다.
/// 설정 탭에서 상세주소 입력 → 앱 재실행 후에도 남아 있는지 → 체크아웃 화면에 그대로 채워지는지.
final class SettingsUITests: XCTestCase {
    private let detail = "101동 1001호"

    override func setUp() {
        continueAfterFailure = false
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

        let field = app.textFields["field.address2"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "설정에 상세주소 칸이 없음")
        reveal(field, in: app)
        XCTAssertTrue(app.staticTexts["상세주소"].exists, "상세주소 칸 이름이 안 보임")
        field.tap()
        field.typeText(detail)
        XCTAssertEqual(field.value as? String, detail)
        dismissKeyboard(app)
        let preview = app.staticTexts["addressPreview"]
        reveal(preview, in: app)
        XCTAssertTrue(preview.label.contains(detail), "입력된 주소 미리보기에 상세주소 없음: \(preview.label)")
        shot("1-settings-entered")

        // 2) 앱을 완전히 껐다 켜도 남아 있는지
        app.terminate()
        app.launchArguments = ["-uitest"]
        app.launch()
        openTab(app, "설정")
        let again = app.textFields["field.address2"]
        XCTAssertTrue(again.waitForExistence(timeout: 10))
        reveal(again, in: app)
        XCTAssertEqual(again.value as? String, detail, "재실행 후 상세주소가 사라짐")
        shot("2-settings-after-relaunch")

        // 3) 체크아웃 모양 테스트 페이지에 그대로 채워지는지
        openTab(app, "Supreme")
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 15), "웹 화면이 안 뜸")
        let webDetail = web.textFields["상세주소"]
        XCTAssertTrue(webDetail.waitForExistence(timeout: 15), "체크아웃 상세주소 칸을 못 찾음")
        let filled = expectation(for: NSPredicate(format: "value == %@", detail), evaluatedWith: webDetail)
        wait(for: [filled], timeout: 20)
        shot("3-checkout-filled")

        // 결제 버튼은 눌리지 않았어야 함 (누르면 제목이 PAID로 바뀌게 해 둠)
        XCTAssertFalse(web.staticTexts["PAID"].exists)
    }
}

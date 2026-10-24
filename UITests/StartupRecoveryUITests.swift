import XCTest

/// One manually requested workflow on an isolated Debug simulator library.
@MainActor final class StartupRecoveryUITests: XCTestCase {
    func testStartupAndIndexRecovery() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This isolated UI check is simulator-only; never launch against a device library.")
        #endif
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "studio.mycover.app")
        app.launchArguments = ["--startup-ui-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.staticTexts["本地作品库未能打开"].waitForExistence(timeout: 30))
        capture(app, "01-startup-failure")
        tap(app.buttons["保留事务日志并重新打开…"], in: app)
        tap(app.buttons["保留日志，重试打开作品库"], in: app)
        dismissNotice(app)
        let library = app.tabBars.buttons["作品库"]
        XCTAssertTrue(library.waitForExistence(timeout: 20)); library.tap()
        XCTAssertTrue(app.staticTexts["启动验证 · 保留作品"].firstMatch.waitForExistence(timeout: 15))
        capture(app, "02-library-with-damaged-index")
        tap(app.buttons["library-issue-22222222-2222-4222-8222-222222222222"], in: app)
        tap(app.buttons["校验上一版索引与全部登记素材"], in: app)
        XCTAssertTrue(app.buttons["创建独立恢复副本"].waitForExistence(timeout: 20))
        capture(app, "03-verified-previous-index")
        tap(app.buttons["创建独立恢复副本"], in: app)
        tap(app.buttons["保留原目录，创建恢复副本"], in: app)
        dismissNotice(app)
        XCTAssertTrue(app.staticTexts["启动验证 · 待恢复作品（索引恢复副本）"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["library-issue-22222222-2222-4222-8222-222222222222"].exists)
        capture(app, "04-recovered-copy-original-still-listed")
        tap(app.buttons["存储管理"], in: app)
        tap(app.buttons["浏览并另存原件"], in: app)
        XCTAssertTrue(app.staticTexts["media/retained-original.wav"].waitForExistence(timeout: 20))
        capture(app, "05-safety-originals-with-invalid-index")
        tap(app.navigationBars["工程索引恢复"].buttons["完成"], in: app)
        tap(app.navigationBars["存储管理"].buttons["完成"], in: app)
        tap(app.buttons["设置"], in: app)
        tap(app.buttons["保留的启动恢复日志"], in: app)
        XCTAssertTrue(app.navigationBars["启动恢复日志"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["保存副本到 Files"].waitForExistence(timeout: 15))
        capture(app, "06-retained-startup-log")
    }
    private func dismissNotice(_ app: XCUIApplication) {
        let notice = app.alerts["工程提示"]
        XCTAssertTrue(notice.waitForExistence(timeout: 20))
        notice.buttons["知道了"].tap()
    }
    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 15), "Missing: \(element)")
        for _ in 0..<4 {
            if element.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, "Not hittable: \(element)")
        element.tap()
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

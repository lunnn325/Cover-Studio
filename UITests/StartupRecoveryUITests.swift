import XCTest
import UIKit

/// One manually requested workflow on an isolated Debug simulator library.
@MainActor final class StartupRecoveryUITests: XCTestCase {
    func testStartupAndIndexRecovery() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This isolated UI check is simulator-only; never launch against a device library.")
        #endif
        continueAfterFailure = false
        let widePad = UIDevice.current.userInterfaceIdiom == .pad
        if widePad { XCUIDevice.shared.orientation = .landscapeLeft }
        defer { if widePad { XCUIDevice.shared.orientation = .portrait } }
        let app = XCUIApplication(bundleIdentifier: "studio.mycover.app")
        app.launchArguments = ["--startup-ui-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.staticTexts["本地作品库未能打开"].waitForExistence(timeout: 30))
        if widePad { XCTAssertGreaterThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height) }
        capture(app, "01-startup-failure")
        tap(app.buttons["保留事务日志并重新打开…"], in: app)
        tap(app.buttons["保留日志，重试打开作品库"], in: app)
        dismissNotice(app)
        let library = app.buttons["作品库"].firstMatch
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
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 15))
        let settingsList = try XCTUnwrap(app.collectionViews.allElementsBoundByIndex.last)
        tap(app.buttons["保留的启动恢复日志"], in: app, scrolling: settingsList)
        XCTAssertTrue(app.navigationBars["启动恢复日志"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["保存副本到 Files"].waitForExistence(timeout: 15))
        capture(app, "06-retained-startup-log")
        tap(app.navigationBars["启动恢复日志"].buttons["完成"], in: app)
        tap(app.navigationBars["设置"].buttons["完成"], in: app)
        tap(app.buttons["录制"].firstMatch, in: app)
        XCTAssertTrue(app.buttons["record-prepare"].waitForExistence(timeout: 15))
        if widePad { XCTAssertTrue(app.otherElements["record-wide-layout"].firstMatch.exists) }
        capture(app, "07-record-empty-lyrics")
        tap(app.buttons["record-lyrics"], in: app)
        let editor = app.textViews["lyrics-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15)); editor.tap()
        editor.typeText("[00:00.00]Saved first line\n[00:05.00]Saved second line")
        tap(app.buttons["lyrics-save"], in: app)
        XCTAssertTrue(app.staticTexts["Saved first line"].waitForExistence(timeout: 15))
        capture(app, "08-record-saved-lrc")
        tap(app.buttons["练习"].firstMatch, in: app)
        let practiceList = app.collectionViews.firstMatch
        tap(app.buttons["practice-lyrics"], in: app, scrolling: practiceList)
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertTrue((editor.value as? String ?? "").contains("Saved second line"))
        editor.tap(); editor.typeText("\nRevised plain lyric\n")
        tap(app.buttons["lyrics-save"], in: app)
        // Reopen the actual saved project after process termination, not just the sheet draft.
        app.terminate()
        app.launchArguments = ["--resume-startup-ui-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch(); dismissNotice(app)
        tap(app.buttons["录制"].firstMatch, in: app)
        XCTAssertTrue(app.staticTexts["Revised plain lyric"].waitForExistence(timeout: 15))
        capture(app, "09-record-lyrics-after-relaunch")
        tap(app.buttons["record-lyrics"], in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertTrue((editor.value as? String ?? "").contains("Revised plain lyric"))
        capture(app, "10-reopened-lyrics-editor")
    }
    private func dismissNotice(_ app: XCUIApplication) {
        let notice = app.alerts["工程提示"]
        XCTAssertTrue(notice.waitForExistence(timeout: 20))
        notice.buttons["知道了"].tap()
    }
    private func tap(_ element: XCUIElement, in app: XCUIApplication, scrolling container: XCUIElement? = nil) {
        // Lazy List rows may not exist until scrolled into a short iPad sheet.
        _ = element.waitForExistence(timeout: container == nil ? 15 : 2)
        for _ in 0..<4 {
            if element.exists && element.isHittable { break }
            (container ?? app).swipeUp()
            _ = element.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(element.exists, "Missing: \(element)")
        XCTAssertTrue(element.isHittable, "Not hittable: \(element)")
        element.tap()
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        // Application-region screenshots were cropped in iPad landscape; keep the full display.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

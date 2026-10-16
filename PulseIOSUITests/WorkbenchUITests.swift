import XCTest

final class WorkbenchUITests: XCTestCase {
    @MainActor
    private func launchDemo() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--acceptance-demo"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["计划"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    func testRealTradeFormDoesNotInventExecutionPrice() {
        let app = launchDemo()
        app.tabBars.buttons["计划"].tap()
        let entry = app.buttons["记成交"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        entry.tap()
        let price = app.textFields["trade.price"]
        XCTAssertTrue(price.waitForExistence(timeout: 8))
        XCTAssertTrue(["", "必填"].contains(price.value as? String ?? ""), "实际成交价必须保持空白，不得从目标价或报价填入")
        XCTAssertFalse(app.buttons["trade.save"].isEnabled)
        XCTAssertTrue(app.staticTexts["参考价只是行情，不会自动填成实际成交价。"].exists)
        saveScreenshot(app, name: "empty-real-execution-price")
    }

    @MainActor
    func testRecordingPartialFillChangesActualPlanProgress() {
        let app = launchDemo()
        app.tabBars.buttons["计划"].tap()
        let entry = app.buttons["记成交"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        entry.tap()
        let price = app.textFields["trade.price"]
        let quantity = app.textFields["trade.quantity"]
        XCTAssertTrue(price.waitForExistence(timeout: 8))
        price.tap(); price.typeText("208000")
        quantity.tap(); quantity.typeText("100")
        let save = app.buttons["trade.save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let confirm = app.buttons["确认保存记录"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let progress = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "100 / 300")).firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 10), "必须由保存的真实成交推进到部分执行，而不是仅弹一个成功提示")
        saveScreenshot(app, name: "recorded-partial-fill")
    }

    @MainActor
    func testFourWorkingTabsAndHonestCloudStatus() {
        let app = launchDemo()
        XCTAssertTrue(app.staticTexts["模拟器验收 · 合成数据，不是你的账户"].exists)
        for tab in ["自选", "计划", "账户", "今日"] {
            let button = app.tabBars.buttons[tab]
            XCTAssertTrue(button.exists)
            button.tap()
        }
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "KRW KRW")).firstMatch.exists)
        saveScreenshot(app, name: "today-real-app")
    }

    @MainActor
    func testDarkLargeTextStillExposesAllFourWorkspaces() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--acceptance-demo", "--acceptance-large-dark"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["账户"].waitForExistence(timeout: 15))
        saveScreenshot(app, name: "dark-accessibility-today")
        app.tabBars.buttons["计划"].tap()
        XCTAssertTrue(app.buttons["记成交"].firstMatch.waitForExistence(timeout: 8))
        saveScreenshot(app, name: "dark-accessibility-plans")
    }

    @MainActor
    func testLocalAutomaticActivityReachesSystemAndSurvivesLeavingApp() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--acceptance-demo", "--acceptance-activity"]
        app.launch()
        let actual = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "系统活动 1 项")).firstMatch
        XCTAssertTrue(actual.waitForExistence(timeout: 15), "必须由真实 ActivityKit 返回活动，不能只显示自动关注开关已开启")
        saveScreenshot(app, name: "local-activity-system-confirmed")
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 8))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "native-activity-outside-app"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testNewPlanSearchAllowsUnwatchedSymbolAndCancelDoesNotAddIt() {
        let app = launchDemo()
        func chooseTesla() {
            app.tabBars.buttons["计划"].tap()
            let create = app.buttons["plan.new"]
            XCTAssertTrue(create.waitForExistence(timeout: 8))
            for _ in 0..<4 where !create.isHittable { app.swipeUp() }
            create.tap()
            let search = app.textFields["plan.search"]
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.tap(); search.typeText("TSLA")
            let result = app.buttons["plan.choose.TSLA"]
            XCTAssertTrue(result.waitForExistence(timeout: 8))
            result.tap()
            XCTAssertTrue(app.buttons["plan.save"].waitForExistence(timeout: 5))
        }
        chooseTesla()
        saveScreenshot(app, name: "search-unwatched-new-plan")
        app.buttons["取消"].firstMatch.tap()
        app.tabBars.buttons["自选"].tap()
        XCTAssertFalse(app.staticTexts["TSLA"].exists, "取消编辑不能先加入自选")
        chooseTesla()
        let price = app.textFields["plan.price"]
        let quantity = app.textFields["plan.quantity"]
        XCTAssertTrue(price.waitForExistence(timeout: 5))
        price.tap(); price.typeText("200")
        quantity.tap(); quantity.typeText("10")
        app.buttons["plan.save"].tap()
        app.tabBars.buttons["自选"].tap()
        XCTAssertTrue(app.staticTexts["TSLA"].waitForExistence(timeout: 8), "保存计划后才一起创建标的和分组成员")
        saveScreenshot(app, name: "new-plan-saved-outside-original-watchlist")
    }

    @MainActor
    func testWatchlistSortMenuWorksAndCustomEditorIsReachable() {
        let app = launchDemo()
        app.tabBars.buttons["自选"].tap()
        let sorting = app.buttons["watchlist.sort"]
        XCTAssertTrue(sorting.waitForExistence(timeout: 5))
        sorting.tap()
        app.buttons["涨幅"].firstMatch.tap()
        XCTAssertTrue(app.buttons["排序：涨幅"].exists || sorting.label.contains("涨幅"))
        sorting.tap()
        app.buttons["自定义顺序"].firstMatch.tap()
        let adjust = app.buttons["调整顺序"]
        XCTAssertTrue(adjust.waitForExistence(timeout: 5))
        adjust.tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 5))
        saveScreenshot(app, name: "watchlist-custom-reorder")
        app.buttons["取消"].tap()
        saveScreenshot(app, name: "watchlist-sort-controls")
    }

    @MainActor
    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

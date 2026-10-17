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
    func testHistoryReviewShortcutSavesTheActualRecordAndClearsBacklog() {
        let app = launchDemo()
        // Revisit an already mounted account page in a different section: the
        // shortcut must select Reviews, not merely change the active tab.
        app.tabBars.buttons["账户"].tap()
        let sections = app.segmentedControls["account.sections"]
        XCTAssertTrue(sections.waitForExistence(timeout: 5))
        sections.buttons["流水"].tap()
        app.tabBars.buttons["今日"].tap()

        let pending = openHistoryReviews(app)
        let pendingID = pending.identifier
        let completedID = pendingID.replacingOccurrences(of: "review.pending.", with: "review.completed.")
        saveScreenshot(app, name: "history-review-shortcut")
        pending.tap()
        let field = retrospectiveField(app)
        let text = "Waited for confirmation before buying."
        field.tap(); field.typeText(text)
        app.buttons["review.save"].tap()

        let completed = app.buttons[completedID]
        XCTAssertTrue(completed.waitForExistence(timeout: 8))
        XCTAssertTrue(completed.label.contains(text), "必须展示同一笔成交实际保存的复盘")
        XCTAssertFalse(app.buttons[pendingID].exists)
        saveScreenshot(app, name: "history-review-saved")
        app.tabBars.buttons["今日"].tap()
        XCTAssertTrue(app.buttons["today.reviewBacklog"].waitForNonExistence(timeout: 8), "唯一历史成交完成复盘后，工作台不能仍显示待补齐")
    }

    @MainActor
    func testDarkLargeHistoryReviewCancellationKeepsRecordPending() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--acceptance-demo", "--acceptance-large-dark"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["今日"].waitForExistence(timeout: 15))
        let pending = openHistoryReviews(app)
        let pendingID = pending.identifier
        let completedID = pendingID.replacingOccurrences(of: "review.pending.", with: "review.completed.")
        saveScreenshot(app, name: "dark-large-history-reviews")
        pending.tap()
        let field = retrospectiveField(app)
        let cancelledText = "This draft must not be saved."
        field.tap(); field.typeText(cancelledText)
        saveScreenshot(app, name: "dark-large-history-review-editor")
        app.buttons["review.cancel"].tap()

        let unchanged = app.buttons[pendingID]
        XCTAssertTrue(unchanged.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons[completedID].exists)
        unchanged.tap()
        let reopened = retrospectiveField(app)
        XCTAssertFalse((reopened.value as? String ?? "").contains(cancelledText))
        app.buttons["review.cancel"].tap()
        app.tabBars.buttons["今日"].tap()
        XCTAssertTrue(app.buttons["today.reviewBacklog"].waitForExistence(timeout: 8))
    }

    @MainActor
    func testAShareStagesChangeActualTasksAndActionsWithoutInventingForeignAccounts() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--acceptance-demo", "--acceptance-a-shares"]
        app.launch()
        XCTAssertTrue(app.segmentedControls["today.phase"].waitForExistence(timeout: 15))
        let assets = app.staticTexts["today.assetMarket"]
        XCTAssertTrue(assets.label.contains("A 股资产"))
        XCTAssertFalse(app.segmentedControls["today.scope"].exists, "全球参考指数不等于港股/美股账户")
        let clock = app.staticTexts["today.marketClock"].label
        XCTAssertFalse(clock.contains("港股"))
        XCTAssertFalse(clock.contains("美股"))

        choosePhase("盘前", in: app)
        XCTAssertEqual(app.staticTexts["today.stage.title"].label, "盘前准备")
        XCTAssertTrue(app.staticTexts["today.metric.plans"].exists)
        XCTAssertTrue(app.buttons["today.preparePlans"].exists)
        saveScreenshot(app, name: "a-share-preparation")
        let quiet = app.buttons["today.task.600000.SH"]
        reveal(quiet, in: app)
        quiet.tap()
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "today.recordFill.")).count, 0,
            "准备清单不能把计划当成已成交")

        choosePhase("盘中", in: app)
        XCTAssertEqual(app.staticTexts["today.stage.title"].label, "盘中跟进")
        XCTAssertTrue(app.staticTexts["today.metric.reached"].exists)
        XCTAssertFalse(app.buttons["today.task.600000.SH"].exists, "未到价且无待核对条件的安静计划只属于准备清单")
        XCTAssertFalse(app.buttons["today.writeReviews"].exists)
        saveScreenshot(app, name: "a-share-intraday")
        let follow = app.buttons["today.task.000001.SZ"]
        reveal(follow, in: app)
        follow.tap()
        let fill = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "today.recordFill.000001.SZ.")).firstMatch
        XCTAssertTrue(fill.waitForExistence(timeout: 5))
        fill.tap()
        let actualPrice = app.textFields["trade.price"]
        XCTAssertTrue(actualPrice.waitForExistence(timeout: 5))
        XCTAssertTrue(["", "必填"].contains(actualPrice.value as? String ?? ""))
        app.buttons["trade.cancel"].tap()

        choosePhase("盘后", in: app)
        XCTAssertEqual(app.staticTexts["today.stage.title"].label, "盘后复盘")
        XCTAssertTrue(app.staticTexts["today.metric.fills"].label.contains("1"))
        XCTAssertTrue(app.staticTexts["today.metric.reviews"].label.contains("1"))
        XCTAssertFalse(app.staticTexts["today.metric.reached"].exists)
        XCTAssertFalse(app.buttons["today.task.600000.SH"].exists)
        XCTAssertTrue(app.buttons["today.writeReviews"].exists)
        saveScreenshot(app, name: "a-share-post-market")
        reveal(app.buttons["today.task.000001.SZ"], in: app)
        app.buttons["today.task.000001.SZ"].tap()
        let review = app.buttons["today.reviewFill.000001.SZ"]
        reveal(review, in: app)
        review.tap()
        XCTAssertTrue(app.buttons["review.save"].waitForExistence(timeout: 5))
        app.buttons["review.cancel"].tap()
    }

    @MainActor
    func testAShareStagesSupportAirDarkLargeText() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--acceptance-demo", "--acceptance-a-shares", "--acceptance-large-dark"]
        app.launch()
        XCTAssertTrue(app.segmentedControls["today.phase"].waitForExistence(timeout: 15))
        for (phase, title) in [("盘前", "盘前准备"), ("盘中", "盘中跟进"), ("盘后", "盘后复盘")] {
            choosePhase(phase, in: app)
            XCTAssertEqual(app.staticTexts["today.stage.title"].label, title)
            saveScreenshot(app, name: "air-dark-large-\(phase)")
        }
    }

    @MainActor
    private func choosePhase(_ phase: String, in app: XCUIApplication) {
        let picker = app.segmentedControls["today.phase"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        for _ in 0..<8 where !picker.isHittable { app.swipeDown() }
        XCTAssertTrue(picker.isHittable)
        picker.buttons[phase].tap()
    }

    @MainActor
    private func openHistoryReviews(_ app: XCUIApplication) -> XCUIElement {
        let shortcut = app.buttons["today.reviewBacklog"]
        reveal(shortcut, in: app)
        shortcut.tap()
        let pending = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "review.pending.005930.KS.")).firstMatch
        reveal(pending, in: app)
        XCTAssertTrue(app.tabBars.buttons["账户"].isSelected)
        let activeAccount = app.buttons["account.choice.mengmeng"]
        XCTAssertTrue(activeAccount.isSelected)
        XCTAssertGreaterThanOrEqual(activeAccount.frame.minX, app.frame.minX, "当前账户不能被横向裁掉")
        XCTAssertLessThanOrEqual(activeAccount.frame.maxX, app.frame.maxX, "大字下也必须看清当前记账账户")
        return pending
    }

    @MainActor
    private func retrospectiveField(_ app: XCUIApplication) -> XCUIElement {
        // A multiline SwiftUI TextField is exposed as a text view on some OS
        // versions. Match its explicit identity rather than its implementation.
        let field = app.descendants(matching: .any).matching(identifier: "review.retrospective").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(field.isHittable)
        return field
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 8))
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

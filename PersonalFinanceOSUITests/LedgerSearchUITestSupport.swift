import XCTest

extension XCUIApplication {
    @MainActor
    func submitLedgerSearch(_ query: String, file: StaticString = #filePath, line: UInt = #line) {
        buttons["搜索"].tap()
        let field = textFields["transaction-search-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), file: file, line: line)
        field.tap()
        field.typeText(query + "\n")
        XCTAssertTrue(keyboards.firstMatch.waitForNonExistence(timeout: 5), file: file, line: line)
    }

    @MainActor
    func searchAllTransactions(for query: String, file: StaticString = #filePath, line: UInt = #line) {
        submitLedgerSearch(query, file: file, line: line)
        segmentedControls["transaction-search-scope"].buttons["全部记录"].tap()
        XCTAssertTrue(staticTexts["transactions-all-history-title"].waitForExistence(timeout: 5), file: file, line: line)
        buttons["收起"].tap()
    }
}

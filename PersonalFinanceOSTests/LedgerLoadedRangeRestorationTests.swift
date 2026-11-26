import XCTest
@testable import PersonalFinanceOS

final class LedgerLoadedRangeRestorationTests: XCTestCase {
    func testOffscreenTailMovedToEndDoesNotMaterializeFiftyThousandDetails() {
        let original = (0..<50_000).map { _ in UUID() }
        var reordered = original
        let offscreen = reordered.remove(at: 99)
        reordered.append(offscreen)
        let count = LedgerLoadedRangeRestoration.range(resultIDs: reordered,
            previousIDs: original, previousRange: 0..<100, anchorID: original[20], keepsPresentation: true).count
        XCTAssertLessThanOrEqual(count, 200, "A moved offscreen target must not expand the detail page to the entire result")
    }

    func testTopInsertionsKeepVisibleLoadedTail() {
        let original = (0..<305).map { _ in UUID() }
        let inserted = (0..<26).map { _ in UUID() }
        let range = LedgerLoadedRangeRestoration.range(resultIDs: inserted + original,
            previousIDs: original, previousRange: 0..<300,
            anchorID: original[299], keepsPresentation: true)
        XCTAssertEqual(range.count, 300)
        XCTAssertTrue(range.contains(325))
    }
    func testActualVisibleTargetMovedToEndGetsBoundedWindow() {
        let ids = (0..<50_000).map { _ in UUID() }
        var reordered = ids
        let target = reordered.remove(at: 20); reordered.append(target)
        let range = LedgerLoadedRangeRestoration.range(resultIDs: reordered,
            previousIDs: ids, previousRange: 0..<100, anchorID: target, keepsPresentation: true)
        XCTAssertLessThanOrEqual(range.count, 200)
        XCTAssertTrue(range.contains(49_999))
    }

    func testBalancedInsertDeletePreservesActualTailWithoutNetCountGrowth() {
        let original = (0..<50_000).map { _ in UUID() }
        let inserted = (0..<26).map { _ in UUID() }
        let newIDs = inserted + original.dropLast(26)
        let range = LedgerLoadedRangeRestoration.range(resultIDs: newIDs,
            previousIDs: original, previousRange: 0..<300, anchorID: original[299], keepsPresentation: true)
        XCTAssertTrue(range.contains(325))
        XCTAssertLessThanOrEqual(range.count, 400)
    }

    func testChangedFilterStartsAtFirstPageRatherThanOldWindow() {
        let ids = (0..<50_000).map { _ in UUID() }
        let range = LedgerLoadedRangeRestoration.range(resultIDs: ids, previousIDs: ids,
            previousRange: 49_900..<50_000, anchorID: ids.last, keepsPresentation: false)
        XCTAssertEqual(range, 0..<100)
    }

    func testEmptyResultHasEmptyRange() {
        let range = LedgerLoadedRangeRestoration.range(resultIDs: [], previousIDs: [UUID()],
            previousRange: 0..<1, anchorID: nil, keepsPresentation: true)
        XCTAssertEqual(range, 0..<0)
    }

    func testRepeatedOffscreenInsertionsDoNotGrowDetailBudget() {
        var ids = (0..<100).map { _ in UUID() }
        let anchor = ids[20]
        var range = 0..<100
        for _ in 0..<500 {
            let next = ids + (0..<100).map { _ in UUID() }
            range = LedgerLoadedRangeRestoration.range(resultIDs: next, previousIDs: ids,
                previousRange: range, anchorID: anchor, keepsPresentation: true)
            XCTAssertEqual(range, 0..<100)
            ids = next
        }
    }

    func testTopInsertPreservesVisibleTailWhenPrimaryIsStillInsideOldBounds() {
        let original = (0..<328).map { _ in UUID() }
        let result = [UUID()] + original
        let range = LedgerLoadedRangeRestoration.range(resultIDs: result, previousIDs: original,
            previousRange: 0..<328, anchorID: original[320], keepsPresentation: true)
        XCTAssertEqual(range, 1..<329)
        XCTAssertTrue(range.contains(328))
        XCTAssertEqual(range.count, 328)
    }

}

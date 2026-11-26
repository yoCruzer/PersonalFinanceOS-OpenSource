import Foundation

/// Bounds detail materialization independently of the complete result IDs and totals.
enum LedgerLoadedRangeRestoration {
    static func range(resultIDs: [UUID], previousIDs: [UUID], previousRange: Range<Int>,
                      anchorID: UUID?, keepsPresentation: Bool, pageSize: Int = 100) -> Range<Int> {
        guard !resultIDs.isEmpty else { return 0..<0 }
        guard keepsPresentation else { return 0..<min(pageSize, resultIDs.count) }
        // Only explicit paging grows the detail budget. Automatic refreshes move
        // that window around the real target, never accumulate insertion slack.
        let capacity = min(resultIDs.count, max(pageSize, previousRange.count))
        var start = min(previousRange.lowerBound, max(0, resultIDs.count - capacity))
        if let anchorID, let index = resultIDs.firstIndex(of: anchorID) {
            let oldIndex = previousIDs.firstIndex(of: anchorID) ?? previousRange.lowerBound
            let relative = min(capacity - 1, max(0, oldIndex - previousRange.lowerBound))
            // Move the entire bounded window by the visible target's displacement.
            // This also keeps neighbouring visible tail rows after top insertions,
            // even when the primary target itself still lies inside the old bounds.
            start = min(max(0, index - relative), resultIDs.count - capacity)
        }
        return start..<(start + capacity)
    }
}

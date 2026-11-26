import SwiftUI

/// Signed net amounts are presentation facts, not nonnegative persisted Money values.
struct PFPrimaryAmount: View {
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .largeTitle) private var scale: CGFloat = 1
    let minorUnits: Int64
    var pointSize: CGFloat = 32
    var color: Color = PFColor.expense

    var body: some View {
        PFCompleteAmount(text: SignedAmountFormatting.text(minorUnits, locale: locale))
            .font(.system(size: pointSize * min(scale, 2), weight: .semibold, design: .rounded))
            .foregroundStyle(color)
    }
}

/// Use the available height before reducing financial facts to unreadably small type.
/// A narrow layout wraps at grouping separators; each digit group and the cents stay intact.
struct PFCompleteAmount: View {
    @Environment(\.locale) private var locale
    let text: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(text).fixedSize()
            AmountGroupLayout {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    Text(group).fixedSize()
                }
            }
        }
        .monospacedDigit()
        .accessibilityRepresentation { Text(text) }
    }

    private var groups: [String] {
        let separator = locale.groupingSeparator ?? ","
        let parts = text.components(separatedBy: separator)
        return parts.enumerated().map { index, part in
            part + (index < parts.count - 1 ? separator : "")
        }
    }
}

/// Explicit group placement avoids Text's emergency character wrapping at large sizes.
private struct AmountGroupLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(width: proposal.width ?? .greatestFiniteMagnitude, subviews: subviews)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, frame) in frames(width: bounds.width, subviews: subviews).enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        return subviews.map { view in
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width + 0.5 {
                x = 0; y += rowHeight; rowHeight = 0
            }
            let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            x += size.width
            rowHeight = max(rowHeight, size.height)
            return frame
        }
    }
}

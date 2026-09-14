import SwiftUI

extension Int {
    /// Thousand separators, as the workflow prints downloads.
    var grouped: String { formatted(.number) }

    /// A signed delta, or `nil` when nothing moved — a row should show a change
    /// only when there is one.
    var signedDelta: String? {
        guard self != 0 else { return nil }
        return self > 0 ? "+\(grouped)" : grouped
    }
}

extension Metric {
    /// Whether a rising count is good news. Issues are the exception, and
    /// colouring them like stars is how a growing backlog goes unnoticed.
    var risingIsGood: Bool { self != .issues }

    func deltaColor(_ delta: Int) -> Color {
        if delta == 0 { return .secondary }
        return (delta > 0) == risingIsGood ? .green : .orange
    }
}

/// A wrapping row of chips: five metrics do not fit on one line of an iPhone,
/// and truncating them hides exactly the number you opened the app for.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = layout(subviews: subviews, width: bounds.width)
        for row in rows {
            var x = bounds.minX
            for index in row.range {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var range: Range<Int>
        var y: CGFloat
        var height: CGFloat
        var width: CGFloat
    }

    private func layout(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var start = 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append(Row(range: start..<index, y: y, height: rowHeight, width: x - spacing))
                start = index
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        if start < subviews.count {
            rows.append(Row(range: start..<subviews.count, y: y, height: rowHeight, width: max(0, x - spacing)))
        }
        return rows
    }
}

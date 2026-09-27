import Propofol
import SwiftUI

extension StorageBreakdown.Segment.Kind {
    /// A rank past the palette's end shares its last color.
    var color: Color {
        switch self {
        case let .entry(rank): Theme.Storage.ranked[min(rank, Theme.Storage.ranked.count - 1)]
        case .grouped: Theme.Storage.grouped
        case .other: Theme.Storage.other
        }
    }
}

// MARK: - Volume overview

/// The volume's name and fill, its capacity bar, and the bar's legend.
struct StorageVolumeOverview: View {
    let volume: StorageInventory.Volume
    let breakdown: StorageBreakdown

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            StorageVolumeHeader(name: volume.name, used: volume.used, capacity: volume.capacity)
            StorageCapacityBar(
                segments: breakdown.segments,
                capacity: breakdown.capacity,
                available: breakdown.available,
            )
            StorageLegend(segments: breakdown.segments)
        }
        .padding(.vertical, Theme.Space.xs)
    }
}

struct StorageVolumeHeader: View {
    let name: String
    let used: Int64
    let capacity: Int64

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).font(.headline)
            Spacer(minLength: Theme.Space.md)
            Text("\(StorageSettings.size(used)) of \(StorageSettings.size(capacity)) used")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Capacity bar

/// One rounded bar the width of the pane: a colored run per segment, and the
/// track showing through for the space still available.
struct StorageCapacityBar: View {
    let segments: [StorageBreakdown.Segment]
    let capacity: Int64
    let available: Int64

    enum Metrics {
        static let height: CGFloat = 18
        static let cornerRadius: CGFloat = 5
        /// The hairline between neighbors, where the pane shows through.
        static let gap: CGFloat = 1
        /// The narrowest a segment is drawn, so a small entry stays visible.
        static let minimumSegmentWidth: CGFloat = 2
    }

    var body: some View {
        GeometryReader { proxy in
            let widths = Self.widths(of: segments.map(\.bytes), capacity: capacity, in: proxy.size.width)
            HStack(spacing: Metrics.gap) {
                ForEach(Array(zip(segments, widths)), id: \.0.id) { segment, width in
                    Rectangle().fill(segment.kind.color).frame(width: width)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Metrics.height)
        .background(.quaternary)
        .clipShape(.rect(cornerRadius: Metrics.cornerRadius, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(summary)
    }

    /// The bar read aloud: every segment with its size, then what is free.
    private var summary: String {
        (segments.map { "\(InterfaceCopy.localized($0.name)) \(StorageSettings.size($0.bytes))" }
            + [String(localized: "\(StorageSettings.size(available)) available")])
            .joined(separator: ", ")
    }

    /// How wide each segment draws in a bar `width` points across.
    ///
    /// Each takes its share of the capacity, never less than the minimum.
    /// When minimums and gaps push the sum past the bar, the segments wider
    /// than the minimum give the excess back in proportion.
    static func widths(of bytes: [Int64], capacity: Int64, in width: CGFloat) -> [CGFloat] {
        guard capacity > 0, width > 0 else { return bytes.map { _ in 0 } }
        let usable = max(0, width - Metrics.gap * CGFloat(bytes.count))
        let minimum = Metrics.minimumSegmentWidth
        let natural = bytes.map { max(minimum, CGFloat($0) / CGFloat(capacity) * width) }
        let excess = natural.reduce(0, +) - usable
        let shrinkable = natural.map { $0 - minimum }.reduce(0, +)
        guard excess > 0, shrinkable > 0 else { return natural }
        let kept = max(0, 1 - excess / shrinkable)
        return natural.map { minimum + ($0 - minimum) * kept }
    }
}

// MARK: - Legend

/// The color of one segment, as the legend and the rows show it. A row with
/// nothing in the bar passes `nil` and keeps the column's width.
struct StorageDot: View {
    let color: Color?

    static let diameter: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color ?? .clear)
            .frame(width: Self.diameter, height: Self.diameter)
            .accessibilityHidden(true)
    }
}

/// A dot and a name per segment, wrapping onto as many lines as the pane's
/// width asks for.
struct StorageLegend: View {
    let segments: [StorageBreakdown.Segment]

    var body: some View {
        WrappingLayout(spacing: Theme.Space.md, lineSpacing: Theme.Space.xs) {
            ForEach(segments) { segment in
                HStack(spacing: Theme.Space.xs) {
                    StorageDot(color: segment.kind.color)
                    Text(InterfaceCopy.localized(segment.name))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
    }
}

/// Lays subviews out left to right at their ideal sizes and starts a new line
/// when the next one would pass the proposed width.
struct WrappingLayout: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let origins = origins(of: subviews, in: width)
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let right = zip(origins, sizes).map { $0.x + $1.width }.max() ?? 0
        let bottom = zip(origins, sizes).map { $0.y + $1.height }.max() ?? 0
        return CGSize(width: proposal.width ?? right, height: bottom)
    }

    func placeSubviews(
        in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout (),
    ) {
        for (subview, origin) in zip(subviews, origins(of: subviews, in: bounds.width)) {
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified,
            )
        }
    }

    private func origins(of subviews: Subviews, in width: CGFloat) -> [CGPoint] {
        var origins: [CGPoint] = []
        var cursor = CGPoint.zero
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursor.x > 0, cursor.x + size.width > width {
                cursor = CGPoint(x: 0, y: cursor.y + lineHeight + lineSpacing)
                lineHeight = 0
            }
            origins.append(cursor)
            cursor.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return origins
    }
}

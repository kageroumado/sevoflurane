import Foundation

/// How one volume's capacity divides, as the Storage pane's bar draws it: the
/// largest entries of ours each on their own, the rest of ours as one group,
/// everything else on the volume as "Other", and what is left as available.
nonisolated struct StorageBreakdown: Equatable {
    struct Segment: Identifiable, Equatable {
        /// What a segment stands for, which is also what picks its color.
        enum Kind: Hashable {
            /// One of the largest entries; `rank` counts from 0 at the largest.
            case entry(rank: Int)
            /// The sum of our entries below the ranked ones.
            case grouped
            /// What the volume holds that is someone else's.
            case other
        }

        let id: String
        let kind: Kind
        let name: String
        let bytes: Int64
    }

    static let groupedID = "storage.grouped"
    static let otherID = "storage.other"
    static let groupedName = "Other Sevoflurane data"
    static let otherName = "Other"

    /// In bar order: ranked entries, the group, then "Other".
    let segments: [Segment]
    let capacity: Int64
    let available: Int64
    /// Which segment each measured entry of ours is drawn in, by entry id.
    private let kinds: [String: Segment.Kind]

    /// The segment an entry belongs to, or `nil` for one with no bytes.
    func kind(of entry: StorageInventory.Entry) -> Segment.Kind? {
        kinds[entry.id]
    }

    /// Divides a volume between `entries` and everything else on it.
    ///
    /// An entry with no bytes, or a negative count standing for "unmeasured",
    /// takes no part. A linked game is counted by Steam in this bottle and
    /// stored in another, so our total can pass the volume's used figure;
    /// "Other" is floored at zero for that case.
    static func make(
        entries: [StorageInventory.Entry], volumeUsed: Int64, volumeTotal: Int64, colored: Int = 4,
    ) -> StorageBreakdown {
        let measured = entries.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        let ranked = measured.prefix(max(0, colored))
        let rest = measured.dropFirst(ranked.count)

        var segments: [Segment] = []
        var kinds: [String: Segment.Kind] = [:]
        for (rank, entry) in ranked.enumerated() {
            let kind = Segment.Kind.entry(rank: rank)
            segments.append(Segment(id: entry.id, kind: kind, name: entry.name, bytes: entry.bytes))
            kinds[entry.id] = kind
        }
        let groupedBytes = rest.map(\.bytes).reduce(0, +)
        if groupedBytes > 0 {
            segments.append(Segment(id: groupedID, kind: .grouped, name: groupedName, bytes: groupedBytes))
            for entry in rest {
                kinds[entry.id] = .grouped
            }
        }
        let ours = measured.map(\.bytes).reduce(0, +)
        let other = max(0, volumeUsed - ours)
        if other > 0 {
            segments.append(Segment(id: otherID, kind: .other, name: otherName, bytes: other))
        }
        return StorageBreakdown(
            segments: segments,
            capacity: max(0, volumeTotal),
            available: max(0, volumeTotal - volumeUsed),
            kinds: kinds,
        )
    }
}

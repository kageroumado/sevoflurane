import Foundation
import Observation

/// Watches the folders a browser saves into for Apple's toolkit disk image, for
/// the route where the user downloads it in their own browser.
///
/// Downloads is always watched; other folders the user adds are remembered. A
/// folder's direct children and one level below are read, which covers a
/// browser set to ask where to save and a user who files downloads away. A
/// file counts once its size has held still across two looks: browsers write
/// the final name only at the end, but a copy into the folder does not.
@MainActor
@Observable
final class GPTkFolderWatch {
    /// The folders being watched, Downloads first.
    private(set) var folders: [URL]
    private(set) var isWatching = false
    /// Handed each finished disk image once.
    @ObservationIgnored var onFound: (@MainActor (URL) -> Void)?

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var sizes: [URL: Int64] = [:]
    @ObservationIgnored private var handed: Set<URL> = []

    static let downloads = UserHome.url
        .appendingPathComponent("Downloads", isDirectory: true)
    private static let foldersKey = "gptkWatchFolders"
    private static let interval = Duration.seconds(2)

    init() {
        let added = (Preferences.shared.stringArray(forKey: Self.foldersKey) ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        folders = [Self.downloads] + added.filter { $0 != Self.downloads }
    }

    /// Whether a folder is one the user added, and so one they can remove.
    func isRemovable(_ folder: URL) -> Bool {
        folder != Self.downloads
    }

    func add(_ folder: URL) {
        guard !folders.contains(folder) else { return }
        folders.append(folder)
        persist()
    }

    func remove(_ folder: URL) {
        guard isRemovable(folder) else { return }
        folders.removeAll { $0 == folder }
        persist()
    }

    func start() {
        guard loop == nil else { return }
        isWatching = true
        loop = Task(name: "Watch for the toolkit download") { [weak self] in
            while !Task.isCancelled {
                guard let folders = self?.folders else { return }
                let candidates = await Task.detached { Self.candidates(in: folders) }.value
                self?.consider(candidates)
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        isWatching = false
    }

    private func persist() {
        let added = folders.filter(isRemovable).map(\.path)
        Preferences.shared.set(added, forKey: Self.foldersKey)
    }

    /// Hands on each image whose size is the same as at the last look.
    private func consider(_ candidates: [(url: URL, size: Int64)]) {
        var seen: [URL: Int64] = [:]
        for candidate in candidates {
            seen[candidate.url] = candidate.size
            guard !handed.contains(candidate.url),
                  candidate.size > 0, sizes[candidate.url] == candidate.size else { continue }
            handed.insert(candidate.url)
            onFound?(candidate.url)
        }
        sizes = seen
    }

    /// The toolkit images in the folders and one level below them, the
    /// evaluation environment first: it is the one D3DMetal is in, and a
    /// version found twice installs from whichever comes first.
    private nonisolated static func candidates(in folders: [URL]) -> [(url: URL, size: Int64)] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        var found: [(url: URL, size: Int64)] = []
        for folder in folders {
            let top = (try? manager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys, options: .skipsHiddenFiles,
            )) ?? []
            var entries = top
            for entry in top where (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                entries += (try? manager.contentsOfDirectory(
                    at: entry, includingPropertiesForKeys: keys, options: .skipsHiddenFiles,
                )) ?? []
            }
            for entry in entries where GPTkDownload.isToolkitDMG(entry.lastPathComponent) {
                let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                found.append((entry, Int64(size)))
            }
        }
        let isEvaluation = { (url: URL) in url.lastPathComponent.lowercased().hasPrefix("evaluation") }
        return found.sorted { isEvaluation($0.url) && !isEvaluation($1.url) }
    }
}

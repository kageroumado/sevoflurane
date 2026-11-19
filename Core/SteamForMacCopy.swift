import Darwin
import Foundation

/// A game's macOS version that Steam for Mac already has on disk, cloned into
/// the bottle's library so Sevoflurane's Steam installs it without a download.
///
/// `clonefile` (APFS copy-on-write) costs no space until one side changes a
/// file, and each client keeps an independent copy. Steam's install over the
/// clone validates every file and fetches only mismatches, which also covers
/// a copy that changed between the read here and the clone.
nonisolated enum SteamForMacCopy {
    struct Copy: Equatable, Sendable {
        let appID: Int
        let name: String
        /// `steamapps/common/<installdir>` in Steam for Mac's library.
        let directory: URL
        /// The folder name Steam uses for the game in every library.
        let installDir: String
        /// `SizeOnDisk` from Steam for Mac's manifest.
        let bytes: Int64
        let buildID: String?
    }

    enum Refusal: Error, Equatable, CustomStringConvertible {
        case targetExists(URL)
        case otherVolume
        case cloneFailed(String)

        var description: String {
            switch self {
            case let .targetExists(url): "the bottle's library already has \(url.lastPathComponent)"
            case .otherVolume: "Steam for Mac's copy is on another volume, so it cannot be cloned"
            case let .cloneFailed(reason): "the clone failed: \(reason)"
            }
        }
    }

    /// `StateFlags` with every file on disk and nothing pending; a queued,
    /// running or paused update sets more bits.
    static let fullyInstalledOnly = 4

    /// Steam for Mac's copy when it is complete and at rest: nothing pending,
    /// its folder present, no download staged.
    static func copy(appID: Int, root: URL = NativeSteam.root) -> Copy? {
        for steamapps in NativeSteam.steamapps(root: root) {
            let manifest = steamapps.appendingPathComponent("appmanifest_\(appID).acf")
            guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { continue }
            func value(_ key: String) -> String? { SharedGames.manifestValue(key, in: text) }
            guard value("StateFlags").flatMap(Int.init) == fullyInstalledOnly,
                  let installDir = value("installdir"), !installDir.isEmpty, !installDir.contains("/")
            else { return nil }
            let directory = steamapps.appendingPathComponent("common/\(installDir)", isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
            else { return nil }
            let staged = steamapps.appendingPathComponent("downloading/\(appID)")
            guard !FileManager.default.fileExists(atPath: staged.path) else { return nil }
            return Copy(
                appID: appID, name: value("name") ?? "", directory: directory, installDir: installDir,
                bytes: value("SizeOnDisk").flatMap(Int64.init) ?? 0, buildID: value("buildid"),
            )
        }
        return nil
    }

    /// The client's first library, where its install wizard puts a game by
    /// default.
    static var bottleLibrary: URL? {
        SteamLibraries.steamapps().first
    }

    /// The copy, when it can be cloned into the bottle's library now.
    static func offer(appID: Int) -> Copy? {
        guard let copy = copy(appID: appID), let library = bottleLibrary,
              refusal(for: copy, in: library) == nil else { return nil }
        return copy
    }

    enum Taken: Equatable {
        case cloned(Copy, URL, elapsed: Duration)
        /// No complete copy at rest, or the library already has the folder.
        case nothing
        case failed(String)
    }

    /// Clones Steam for Mac's copy into the bottle's library ahead of a macOS
    /// install. A folder already in place is left for Steam to check.
    static func takeForInstall(appID: Int) -> Taken {
        guard let copy = copy(appID: appID) else { return .nothing }
        guard let library = bottleLibrary else { return .failed("the bottle has no Steam library") }
        let started = ContinuousClock.now
        do {
            let target = try clone(copy, into: library)
            return .cloned(copy, target, elapsed: started.duration(to: .now))
        } catch .targetExists {
            return .nothing
        } catch {
            return .failed(error.description)
        }
    }

    static func target(for copy: Copy, in steamapps: URL) -> URL {
        steamapps.appendingPathComponent("common/\(copy.installDir)", isDirectory: true)
    }

    static func refusal(for copy: Copy, in steamapps: URL) -> Refusal? {
        let target = target(for: copy, in: steamapps)
        if FileManager.default.fileExists(atPath: target.path) { return .targetExists(target) }
        guard let source = volume(of: copy.directory), source == volume(of: steamapps) else { return .otherVolume }
        return nil
    }

    /// Clones the copy into `steamapps/common` under a hidden name, then
    /// renames it so the folder appears whole.
    @discardableResult
    static func clone(_ copy: Copy, into steamapps: URL) throws(Refusal) -> URL {
        if let refusal = refusal(for: copy, in: steamapps) { throw refusal }
        let common = steamapps.appendingPathComponent("common", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: common, withIntermediateDirectories: true)
        } catch {
            throw .cloneFailed(error.localizedDescription)
        }
        let staging = common.appendingPathComponent(".\(copy.installDir).sevo-\(getpid())", isDirectory: true)
        let target = target(for: copy, in: steamapps)
        guard clonefile(copy.directory.path, staging.path, 0) == 0 else {
            throw .cloneFailed(String(cString: strerror(errno)))
        }
        guard rename(staging.path, target.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.trashItem(at: staging, resultingItemURL: nil)
            throw .cloneFailed(reason)
        }
        return target
    }

    private static func volume(of url: URL) -> String? {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        return "\(info.f_fsid.val.0):\(info.f_fsid.val.1)"
    }
}

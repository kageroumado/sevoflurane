import Darwin
import Foundation

/// A game's macOS version that Steam for Mac already has on disk, taken into
/// the bottle's library so Sevoflurane's Steam installs it without a download.
///
/// The folder is cloned (`clonefile`, APFS copy-on-write): the clone costs no
/// space until one side changes a file, and each client keeps its own copy,
/// so Steam for Mac's updates, moves and uninstalls never touch the bottle's
/// and the reverse. Steam then installs the game's macOS version over the
/// clone: its validation reads every file and fetches only the ones that do
/// not match the build it installs, which also covers a copy that changed
/// between the moment it was read here and the clone.
nonisolated enum SteamForMacCopy {
    /// Steam for Mac's copy of one game.
    struct Copy: Equatable, Sendable {
        let appID: Int
        let name: String
        /// `steamapps/common/<installdir>` in Steam for Mac's library.
        let directory: URL
        /// The folder name Steam uses for the game in every library.
        let installDir: String
        /// What the copy occupies, as Steam for Mac's manifest says.
        let bytes: Int64
        /// The build Steam for Mac installed.
        let buildID: String?
    }

    /// Why a copy cannot be taken into the bottle.
    enum Refusal: Error, Equatable, CustomStringConvertible {
        /// The bottle's library already has a folder by that name.
        case targetExists(URL)
        /// The copy is on another volume, where a clone cannot reach.
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

    /// Steam's `StateFlags` when every file is on disk and nothing is pending:
    /// an update queued, running or paused sets more bits, and a copy in that
    /// state is mid-write.
    static let fullyInstalledOnly = 4

    /// Steam for Mac's copy of the game when it is complete and at rest:
    /// fully installed with nothing pending, its folder present, and no
    /// download of it staged.
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

    /// The bottle library a copy goes into: the client's first library,
    /// where its install wizard puts a game unless told otherwise.
    static var bottleLibrary: URL? {
        SteamLibraries.steamapps().first
    }

    /// Steam for Mac's copy of the game when it can be cloned into the
    /// bottle's library now.
    static func offer(appID: Int) -> Copy? {
        guard let copy = copy(appID: appID), let library = bottleLibrary,
              refusal(for: copy, in: library) == nil else { return nil }
        return copy
    }

    /// What taking the copy for an install came to.
    enum Taken: Equatable {
        /// Cloned into the library, in `elapsed`.
        case cloned(Copy, URL, elapsed: Duration)
        /// Nothing to take: Steam for Mac has no complete copy at rest, or a
        /// folder of the game's name is already in the library.
        case nothing
        case failed(String)
    }

    /// Clones Steam for Mac's copy into the bottle's library ahead of an
    /// install of the game's macOS version, so Steam checks it rather than
    /// downloads it. A folder already in place is left for Steam to check.
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

    /// Where the copy goes in the bottle library `steamapps`.
    static func target(for copy: Copy, in steamapps: URL) -> URL {
        steamapps.appendingPathComponent("common/\(copy.installDir)", isDirectory: true)
    }

    /// Why the copy cannot go into `steamapps`, or `nil` when it can.
    static func refusal(for copy: Copy, in steamapps: URL) -> Refusal? {
        let target = target(for: copy, in: steamapps)
        if FileManager.default.fileExists(atPath: target.path) { return .targetExists(target) }
        guard let source = volume(of: copy.directory), source == volume(of: steamapps) else { return .otherVolume }
        return nil
    }

    /// Clones the copy into `steamapps/common`, under a hidden name first so
    /// the folder appears whole, and answers where it landed.
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

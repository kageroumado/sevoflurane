import Darwin
import Foundation

/// The symlinks of a macOS version that the bottle's Steam installed, made
/// real for macOS.
///
/// A depot lists a framework's links (`Versions/Current -> A`,
/// `SDL2 -> Versions/Current/SDL2`) as symlink entries. Steam's Windows client
/// creates them as Windows symlinks, and Wine stores each one as an empty file
/// named `<name>?` carrying the reparse data in its `user.WINEREPARSE`
/// attribute. Wine follows that; macOS sees a stray empty file, so a game
/// that loads a framework through `Versions/Current` cannot start. Each such
/// file gets a real symlink beside it: Wine keeps reading its own, and Steam's
/// validation leaves both alone.
nonisolated enum ReparseLinks {
    /// The attribute Wine keeps a reparse point's data in.
    static let attribute = "user.WINEREPARSE"

    /// `IO_REPARSE_TAG_SYMLINK`.
    private static let symlinkTag: UInt32 = 0xA000_000C
    /// `SYMLINK_FLAG_RELATIVE`.
    private static let relativeFlag: UInt32 = 1

    /// The relative target of a symlink reparse buffer, `/`-separated, or
    /// `nil` for any other reparse point and for an absolute link.
    static func relativeTarget(ofReparseData data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count >= 20 else { return nil }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }
        guard u32(0) == symlinkTag, u32(16) & relativeFlag != 0 else { return nil }
        let offset = 20 + u16(8)
        let length = u16(10)
        guard length > 0, length % 2 == 0, offset + length <= bytes.count else { return nil }
        let units = stride(from: offset, to: offset + length, by: 2).map { UInt16(u16($0)) }
        let target = String(decoding: units, as: UTF16.self).replacingOccurrences(of: "\\", with: "/")
        guard !target.hasPrefix("/"), !target.contains("\0") else { return nil }
        return target
    }

    /// Gives every Wine symlink under `directory` a real symlink beside it,
    /// and answers how many it made. A name already taken by a file or a
    /// folder is left alone; a symlink there that points elsewhere is
    /// replaced, since the depot's entry is the current one. A target that
    /// resolves outside `directory` is refused.
    @discardableResult
    static func restore(in directory: URL) -> Int {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard let walk = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        ) else { return 0 }
        var made = 0
        for case let file as URL in walk {
            let name = file.lastPathComponent
            guard name.count > 1, name.hasSuffix("?"), !isCommitLeftover(String(name.dropLast())),
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, values.fileSize == 0,
                  let data = attribute(of: file), let target = relativeTarget(ofReparseData: data)
            else { continue }
            let parent = file.deletingLastPathComponent().resolvingSymlinksInPath()
            let link = parent.appendingPathComponent(String(name.dropLast()))
            let resolved = parent.appendingPathComponent(target).standardizedFileURL.path
            guard resolved == root || resolved.hasPrefix(root + "/") else { continue }
            var status = stat()
            if lstat(link.path, &status) == 0 {
                guard status.st_mode & S_IFMT == S_IFLNK,
                      let existing = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
                      existing != target, unlink(link.path) == 0
                else { continue }
            }
            if symlink(target, link.path) == 0 { made += 1 }
        }
        return made
    }

    /// ``restore(in:)`` over the game's folder when the build installed in
    /// the bottle is its macOS one; `0` for any other game.
    @discardableResult
    static func restoreInstalledMacOSVersion(appID: Int) -> Int {
        guard let manifest = NativeBuildInfo.manifest(appID: appID),
              let data = try? Data(contentsOf: SteamAppInfo.fileURL, options: .alwaysMapped),
              let app = SteamAppInfo.keyValues(appID: appID, in: data),
              NativeBuildInfo.installedBuild(manifest: manifest, depots: NativeBuildInfo.depots(inAppInfo: app)) == .macos,
              let game = SharedGames.installed(appID: appID)
        else { return 0 }
        return restore(in: game.directory)
    }

    /// Steam commits a file under a temporary `rff<hex>.tmp` name and then
    /// renames it; Wine leaves the temporary name's reparse file behind, a
    /// name no depot lists.
    static func isCommitLeftover(_ name: String) -> Bool {
        name.hasPrefix("rff") && name.hasSuffix(".tmp") && name.count > 7
            && name.dropFirst(3).dropLast(4).allSatisfy(\.isHexDigit)
    }

    private static func attribute(of file: URL) -> Data? {
        let size = getxattr(file.path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0, size <= 16 * 1024 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(file.path, attribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        return read == size ? data : nil
    }
}

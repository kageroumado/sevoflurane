import Foundation

/// The capability a native caller presents to this installation's control
/// ports: the daemon's control endpoint, the app's link port, and the page's
/// `/__eval`.
///
/// Binding to 127.0.0.1 keeps other machines out, and every account on this
/// Mac is still a local client. ``LoopbackGate`` tells a web page from a local
/// program by its headers; nothing in a request tells one account from
/// another. The token does: 32 random bytes, hex-encoded, in a file only this
/// account can read (0600 inside a 0700 directory), sent by every native
/// caller as ``header``. A process of another account cannot read the file and
/// so cannot present it. A process of this account can, and that is authority
/// it already holds over the bottle and every file the daemon reaches.
///
/// Each installation keeps its own under its ``AppIdentity/supportFolder``, so
/// a Debug build's token admits nobody to the shipping installation's ports.
nonisolated enum ControlToken {
    /// The request header that carries the token.
    static let header = "X-Sevo-Token"

    /// `<support folder>/Control`, kept at 0700.
    static var directory: URL {
        AppIdentity.supportFolder.appendingPathComponent("Control", isDirectory: true)
    }

    static let fileName = "token"

    /// Random bytes behind one token; the file holds twice as many hex digits.
    static let byteCount = 32

    /// Why the token could not be read or made.
    enum Failure: Error, Equatable, CustomStringConvertible {
        /// The file or its directory belongs to another account, so whatever
        /// it holds may be known to that account.
        case foreignOwner(String)
        /// A symbolic link, a directory or a device where the file should be.
        case notAFile(String)
        /// A system call failed, with its `errno`.
        case system(String, Int32)

        var description: String {
            switch self {
            case let .foreignOwner(path): "\(path) belongs to another account"
            case let .notAFile(path): "\(path) is not a plain file"
            case let .system(path, code): "\(path): \(String(cString: strerror(code)))"
            }
        }
    }

    /// What a token file's owner and mode make of it.
    enum Ownership: Equatable {
        /// This account's plain file, readable by nobody else.
        case usable
        /// This account's file with group or world bits set: the token may
        /// have been read, so it is replaced rather than used.
        case exposed
        case foreignOwner
        case notAFile
    }

    /// This installation's token, made by whichever process asks first. Read
    /// from disk on every call, so a replaced token reaches every process at
    /// its next request.
    static func current() throws -> String {
        try load(in: directory)
    }

    /// Adds the token to `request`. A request sent without one, because the
    /// token could not be read, is answered 401.
    static func authorize(_ request: inout URLRequest) {
        guard let token = try? current() else { return }
        request.setValue(token, forHTTPHeaderField: header)
    }

    /// Whether `presented` is `expected`, compared in time that depends only
    /// on the length. The length itself is public: every token has
    /// ``byteCount`` × 2 digits.
    static func matches(_ presented: String?, expected: String) -> Bool {
        guard let presented else { return false }
        let given = Array(presented.utf8)
        let wanted = Array(expected.utf8)
        guard !wanted.isEmpty, given.count == wanted.count else { return false }
        return timingsafe_bcmp(given, wanted, wanted.count) == 0
    }

    /// Judges a token file by its `stat`: a plain file, owned by `user`, with
    /// no group or world permission bits.
    static func judge(owner: uid_t, mode: mode_t, user: uid_t = getuid()) -> Ownership {
        guard mode & S_IFMT == S_IFREG else { return .notAFile }
        guard owner == user else { return .foreignOwner }
        return mode & 0o077 == 0 ? .usable : .exposed
    }

    /// The token kept in `directory`, creating the directory and the token
    /// when either is missing and replacing a token that is exposed or
    /// malformed. Throws, and so fails closed, for a file or directory that
    /// belongs to another account or is not what it should be.
    static func load(in directory: URL) throws -> String {
        try prepare(directory)
        let file = directory.appendingPathComponent(fileName)
        // A creator that loses the race to another process reads the
        // winner's token on the next round.
        for _ in 0 ..< 3 {
            switch try read(file) {
            case let .token(token):
                return token
            case .missing:
                if let token = try create(file, replacing: false) { return token }
            case .unusable:
                if let token = try create(file, replacing: true) { return token }
            }
        }
        throw Failure.system(file.path, EAGAIN)
    }

    // MARK: - The file

    private enum Contents {
        case token(String)
        case missing
        /// Exposed, or not a token at all.
        case unusable
    }

    /// Makes `directory` if it is missing, and holds it to 0700 and this
    /// account.
    private static func prepare(_ directory: URL) throws {
        let parent = directory.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw Failure.system(parent.path, EIO)
        }
        let path = directory.path
        if mkdir(path, 0o700) != 0, errno != EEXIST {
            throw Failure.system(path, errno)
        }
        var info = stat()
        guard lstat(path, &info) == 0 else { throw Failure.system(path, errno) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure.notAFile(path) }
        guard info.st_uid == getuid() else { throw Failure.foreignOwner(path) }
        if info.st_mode & 0o077 != 0, chmod(path, 0o700) != 0 {
            throw Failure.system(path, errno)
        }
    }

    /// Opens without following a link, and without blocking on a FIFO, then
    /// judges what was opened rather than the path.
    private static func read(_ file: URL) throws -> Contents {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT: return .missing
            case ELOOP: throw Failure.notAFile(file.path)
            default: throw Failure.system(file.path, errno)
            }
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Failure.system(file.path, errno) }
        switch judge(owner: info.st_uid, mode: info.st_mode) {
        case .usable: break
        case .exposed: return .unusable
        case .foreignOwner: throw Failure.foreignOwner(file.path)
        case .notAFile: throw Failure.notAFile(file.path)
        }
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        guard count >= 0 else { throw Failure.system(file.path, errno) }
        let text = String(decoding: buffer.prefix(count), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return isWellFormed(text) ? .token(text) : .unusable
    }

    /// Writes a fresh token beside `file` and moves it into place whole, so a
    /// reader sees no file or a complete one. Without `replacing`, a token
    /// another process put there first wins and this answers nil.
    private static func create(_ file: URL, replacing: Bool) throws -> String? {
        let token = generate()
        let staging = file.deletingLastPathComponent()
            .appendingPathComponent(".\(fileName).\(getpid()).\(UInt32.random(in: .min ... .max))")
        let descriptor = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.system(staging.path, errno) }
        defer { unlink(staging.path) }
        let bytes = Array(token.utf8)
        let written = write(descriptor, bytes, bytes.count)
        // The umask can only clear bits, and 0600 is exact whatever it is.
        let permitted = fchmod(descriptor, 0o600)
        close(descriptor)
        guard written == bytes.count, permitted == 0 else { throw Failure.system(staging.path, errno) }
        if replacing {
            guard rename(staging.path, file.path) == 0 else { throw Failure.system(file.path, errno) }
            return token
        }
        if link(staging.path, file.path) == 0 { return token }
        guard errno == EEXIST else { throw Failure.system(file.path, errno) }
        return nil
    }

    private static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        arc4random_buf(&bytes, byteCount)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func isWellFormed(_ text: String) -> Bool {
        text.utf8.count == byteCount * 2 && text.utf8.allSatisfy { byte in
            (0x30 ... 0x39).contains(byte) || (0x61 ... 0x66).contains(byte)
        }
    }
}

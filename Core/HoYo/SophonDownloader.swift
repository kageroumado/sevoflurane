import Darwin
import Foundation

/// Installs, updates and repairs a HoYoverse game from HoYoPlay's servers.
///
/// An install writes each zstd chunk at its offset in a `<file>.sophon`,
/// checks the md5 and moves the file into place; files already matching are
/// kept, so an interrupted install resumes.
///
/// An update range-requests each changed file's diff, applies it, checks the
/// md5 and deletes what the new build dropped; a diff that fails is
/// downloaded whole, and a build too old for diffs is repaired against the
/// current one. `config.ini` names the new build only once every file is in
/// place. Entry points are `@concurrent`: hashing and patching take minutes.
nonisolated struct SophonDownloader: Sendable {
    var api = HoYoAPI()
    /// How many chunks or diffs are in flight at once.
    var parallelism = 16
    /// How long a failed download waits before its second and third try.
    var backoff: [Duration] = [.seconds(2), .seconds(8)]

    typealias ProgressHandler = @Sendable (SophonProgress) -> Void

    /// Why an install or update stopped.
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: - Planning

    /// What bringing a folder to the current build takes.
    struct Plan: Sendable {
        enum Kind: Sendable, Equatable {
            /// The folder already holds the current build.
            case upToDate
            /// Diffs from the folder's build.
            case patch(from: String)
            /// Every file that differs from the current build, downloaded
            /// whole: a fresh install, or a build too old for diffs.
            case download
        }

        let game: HoYoGame
        let installed: String?
        let latest: String
        let kind: Kind
        /// The voice packs the plan covers besides the game's own files.
        let voices: [String]
        /// The most the plan downloads, per the service.
        let downloadSize: Int64
    }

    /// What bringing `folder` to the current build takes, changing nothing.
    /// `voices` apply to a fresh install; an existing one keeps its own.
    @concurrent func plan(game: HoYoGame, folder: URL, voices: [String] = []) async throws -> Plan {
        let installation = HoYoInstallation(game: game, folder: folder)
        let branch = try await api.branch(game)
        let installed = installation.version
        if installed == branch.tag {
            return Plan(game: game, installed: installed, latest: branch.tag, kind: .upToDate, voices: [], downloadSize: 0)
        }
        if let installed, branch.diffTags.contains(installed) {
            let chosen = try await patchManifests(for: installation, branch: branch)
            let size = chosen.compactMap { $0.reference.stats[installed]?.compressedSize }.reduce(0, +)
            return Plan(
                game: game, installed: installed, latest: branch.tag, kind: .patch(from: installed),
                voices: chosen.map(\.reference.matchingField).filter { $0 != HoYoVoice.gameField }, downloadSize: size,
            )
        }
        let build = try await api.build(branch)
        let wanted = installed == nil ? voices : try await detectVoices(installation, build: build)
        let chosen = build.manifests.filter { $0.matchingField == HoYoVoice.gameField || wanted.contains($0.matchingField) }
        return Plan(
            game: game, installed: installed, latest: branch.tag, kind: .download,
            voices: wanted, downloadSize: chosen.map(\.stats.compressedSize).reduce(0, +),
        )
    }

    // MARK: - Install and repair

    /// Downloads the current build into `folder`, keeping matching files.
    @discardableResult
    @concurrent func install(
        game: HoYoGame, into folder: URL, voices: [String], progress: @escaping ProgressHandler = { _ in },
    ) async throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let installation = HoYoInstallation(game: game, folder: folder)
        let branch = try await api.branch(game)
        let build = try await api.build(branch)
        try await download(build: build, into: installation, fields: [HoYoVoice.gameField] + voices, progress: progress)
        try installation.recordVersion(build.tag)
        return build.tag
    }

    /// Downloads the files of `fields` that differ, limited to `only`.
    @concurrent func download(
        build: HoYoAPI.Build, into installation: HoYoInstallation, fields: [String], only: Set<String>? = nil,
        progress: @escaping ProgressHandler,
    ) async throws {
        progress(SophonProgress(phase: .preparing))
        var jobs: [ChunkedFile] = []
        for field in fields {
            guard let manifest = build.manifests.first(where: { $0.matchingField == field }) else {
                throw Failure(description: "build \(build.tag) has no \(HoYoVoice.name(field)) files")
            }
            let files = try await SophonManifest(decoding: api.manifestData(manifest.manifest, from: manifest.manifestDownload)).files
            for file in files where only?.contains(file.path) ?? true {
                jobs.append(ChunkedFile(file: file, source: manifest.chunkDownload))
            }
        }
        progress(SophonProgress(phase: .checking, filesTotal: jobs.count))
        let needed = jobs.enumerated().filter { index, job in
            if index % 200 == 0 { progress(SophonProgress(phase: .checking, filesDone: index, filesTotal: jobs.count)) }
            return !Self.holds(installation.folder.appending(path: job.file.path), size: job.file.size, md5: job.file.md5)
        }.map(\.element)
        let total = needed.reduce(Int64(0)) { $0 + $1.file.size }
        try Self.requireSpace(total, at: installation.folder)
        try await fetch(needed, into: installation.folder, totalBytes: total, progress: progress)
    }

    /// Whether `url` is a file of `size` bytes with `md5`.
    static func holds(_ url: URL, size: Int64, md5: String) -> Bool {
        guard HoYoInstallation.size(of: url) == size else { return false }
        return (try? SophonCodec.md5(of: url)) == md5
    }

    /// Redownloads missing or broken `paths`; the installation must be on the
    /// current build.
    @concurrent func repair(
        _ installation: HoYoInstallation, paths: Set<String>, progress: @escaping ProgressHandler = { _ in },
    ) async throws {
        let branch = try await api.branch(installation.game)
        guard installation.version == branch.tag else {
            throw Failure(description: "the folder holds \(installation.version ?? "no known build"), not \(branch.tag) — update it instead")
        }
        let build = try await api.build(branch)
        let fields = try await [HoYoVoice.gameField] + detectVoices(installation, build: build)
        try await download(build: build, into: installation, fields: fields, only: paths, progress: progress)
    }

    // MARK: - Update

    /// What an update did.
    enum Outcome: Sendable, Equatable {
        case upToDate(String)
        /// `current` files were already new (an interrupted update);
        /// `downloadedWhole` diffs did not apply.
        case patched(from: String, to: String, files: Int, current: Int, downloadedWhole: Int)
        case downloaded(to: String)
    }

    /// Brings an installation to its game's current build.
    @concurrent func update(_ installation: HoYoInstallation, progress: @escaping ProgressHandler = { _ in }) async throws -> Outcome {
        let branch = try await api.branch(installation.game)
        guard let installed = installation.version else {
            throw Failure(description: "\(installation.folder.path) has no config.ini naming its build; install into it instead")
        }
        if installed == branch.tag { return .upToDate(installed) }
        guard branch.diffTags.contains(installed) else {
            let build = try await api.build(branch)
            let fields = try await [HoYoVoice.gameField] + detectVoices(installation, build: build)
            try await download(build: build, into: installation, fields: fields, progress: progress)
            try installation.recordVersion(build.tag)
            return .downloaded(to: build.tag)
        }
        return try await patch(installation, from: installed, branch: branch, progress: progress)
    }

    private func patch(
        _ installation: HoYoInstallation, from installed: String, branch: HoYoAPI.Branch,
        progress: @escaping ProgressHandler,
    ) async throws -> Outcome {
        progress(SophonProgress(phase: .preparing))
        var jobs: [PatchJob] = []
        var deletions: [SophonPatchManifest.Deleted] = []
        var newFiles = Set<String>()
        for (reference, manifest) in try await patchManifests(for: installation, branch: branch) {
            newFiles.formUnion(manifest.files.map(\.path))
            for file in manifest.files {
                guard let diff = file.diffs[installed] else { continue }
                jobs.append(PatchJob(file: file, diff: diff, source: reference.diffDownload, field: reference.matchingField))
            }
            deletions += manifest.deletions[installed] ?? []
        }
        let total = jobs.reduce(Int64(0)) { $0 + $1.file.size }
        try Self.requireSpace((jobs.map(\.file.size).max() ?? 0) + jobs.reduce(0) { $0 + $1.diff.length }, at: installation.folder)
        let (results, failed) = try await apply(jobs, to: installation.folder, totalBytes: total, progress: progress)
        var whole = 0
        if !failed.isEmpty {
            let build = try await api.build(branch)
            let fields = Array(Set(failed.map(\.field)))
            try await download(build: build, into: installation, fields: fields, only: Set(failed.map(\.file.path)), progress: progress)
            whole = failed.count
        }
        progress(SophonProgress(phase: .finishing))
        // Renamed files (hash-named asset blocks) are not on the deletion
        // list: their originals go once no new file has the name.
        let originals = jobs.compactMap(\.diff.original)
        for path in Set(originals + deletions.map(\.path)).subtracting(newFiles) {
            try? FileManager.default.removeItem(at: installation.folder.appending(path: path))
        }
        try installation.recordVersion(branch.tag)
        return .patched(
            from: installed, to: branch.tag, files: results[.patched, default: 0], current: results[.current, default: 0],
            downloadedWhole: whole,
        )
    }

    // MARK: - Voices

    /// The voice packs of `build` that `installation` has files of.
    @concurrent func detectVoices(_ installation: HoYoInstallation, build: HoYoAPI.Build) async throws -> [String] {
        var found: [String] = []
        for manifest in build.manifests where manifest.matchingField != HoYoVoice.gameField {
            let files = try await SophonManifest(decoding: api.manifestData(manifest.manifest, from: manifest.manifestDownload)).files
            if Self.hasAny(of: files.map(\.path), in: installation) { found.append(manifest.matchingField) }
        }
        return found
    }

    /// The game's patch manifest and those of the voice packs installed.
    @concurrent func patchManifests(
        for installation: HoYoInstallation, branch: HoYoAPI.Branch,
    ) async throws -> [(reference: HoYoAPI.PatchManifest, manifest: SophonPatchManifest)] {
        var chosen: [(reference: HoYoAPI.PatchManifest, manifest: SophonPatchManifest)] = []
        for reference in try await api.patchBuild(branch).manifests {
            let manifest = try await SophonPatchManifest(decoding: api.manifestData(reference.manifest, from: reference.manifestDownload))
            guard reference.matchingField == HoYoVoice.gameField || Self.hasAny(of: manifest.files.map(\.path), in: installation)
            else { continue }
            chosen.append((reference, manifest))
        }
        return chosen
    }

    /// Whether any of the first 64 `paths` exists; voice packs are all or
    /// nothing.
    static func hasAny(of paths: [String], in installation: HoYoInstallation) -> Bool {
        paths.prefix(64).contains { path in
            FileManager.default.fileExists(atPath: installation.folder.appending(path: path).path)
        }
    }

    // MARK: - Transfers

    private struct ChunkedFile: Sendable {
        let file: SophonManifest.File
        let source: HoYoAPI.Download
    }

    private struct PatchJob: Sendable {
        let file: SophonPatchManifest.File
        let diff: SophonPatchManifest.Diff
        let source: HoYoAPI.Download
        let field: String
    }

    /// Downloads every chunk, `parallelism` at a time, placing each file when
    /// its last chunk lands.
    private func fetch(
        _ files: [ChunkedFile], into folder: URL, totalBytes: Int64, progress: @escaping ProgressHandler,
    ) async throws {
        let tally = Tally(phase: .downloading, bytesTotal: totalBytes, filesTotal: files.count, report: progress)
        let assembly = Assembly(folder: folder)
        var pending = files.flatMap { job in
            job.file.chunks.map { (job, $0) }
        }.makeIterator()
        for job in files where job.file.chunks.isEmpty {
            try await assembly.finishEmpty(job.file)
            await tally.fileDone()
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            func enqueue() {
                guard let (job, chunk) = pending.next() else { return }
                group.addTask {
                    let data = try await self.chunk(chunk, from: job.source)
                    if let staged = try await assembly.write(data, of: chunk, into: job.file) {
                        try Assembly.place(staged, as: job.file, in: folder)
                        await tally.fileDone()
                    }
                    await tally.add(chunk.size)
                }
            }
            for _ in 0 ..< parallelism { enqueue() }
            while try await group.next() != nil { enqueue() }
        }
        await tally.flush()
    }

    /// One chunk, downloaded, checked and decompressed.
    private func chunk(_ chunk: SophonManifest.Chunk, from source: HoYoAPI.Download) async throws -> Data {
        guard let url = source.url(chunk.name) else { throw Failure(description: "bad chunk URL \(chunk.name)") }
        let data = try await retrying(chunk.name) {
            let (data, response) = try await api.session.data(from: url)
            try HoYoAPI.check(response, for: url)
            guard chunk.compressedMD5.isEmpty || SophonCodec.md5(data) == chunk.compressedMD5 else {
                throw Failure(description: "chunk \(chunk.name) arrived damaged")
            }
            return data
        }
        let bytes = source.compression == 0 ? data : try SophonCodec.decompress(data, expectedSize: Int(chunk.size))
        guard SophonCodec.md5(bytes) == chunk.md5 else {
            throw Failure(description: "chunk \(chunk.name) does not decompress to its checksum")
        }
        return bytes
    }

    /// How one file's diff went.
    private enum Applied: Sendable {
        case patched
        case current
        case failed
    }

    /// Applies each diff, `parallelism` at a time; answers the tally and the
    /// failed jobs.
    private func apply(
        _ jobs: [PatchJob], to folder: URL, totalBytes: Int64, progress: @escaping ProgressHandler,
    ) async throws -> (results: [Applied: Int], failed: [PatchJob]) {
        let tally = Tally(phase: .patching, bytesTotal: totalBytes, filesTotal: jobs.count, report: progress)
        var pending = jobs.makeIterator()
        var results: [Applied: Int] = [:]
        var failed: [PatchJob] = []
        try await withThrowingTaskGroup(of: (PatchJob, Applied).self) { group in
            func enqueue() {
                guard let job = pending.next() else { return }
                group.addTask {
                    let applied = try await self.apply(job, in: folder)
                    await tally.add(job.file.size)
                    await tally.fileDone()
                    return (job, applied)
                }
            }
            for _ in 0 ..< parallelism { enqueue() }
            while let (job, applied) = try await group.next() {
                results[applied, default: 0] += 1
                if applied == .failed { failed.append(job) }
                enqueue()
            }
        }
        await tally.flush()
        return (results, failed)
    }

    /// Downloads and applies one diff.
    private func apply(_ job: PatchJob, in folder: URL) async throws -> Applied {
        let target = folder.appending(path: job.file.path)
        if Self.holds(target, size: job.file.size, md5: job.file.md5) { return .current }
        var old: URL?
        if let original = job.diff.original {
            let url = folder.appending(path: original)
            guard HoYoInstallation.size(of: url) == job.diff.originalSize else { return .failed }
            old = url
        }
        guard let url = job.source.url(job.diff.blob) else { throw Failure(description: "bad diff URL \(job.diff.blob)") }
        let range = "bytes=\(job.diff.offset)-\(job.diff.offset + job.diff.length - 1)"
        let diff = try await retrying(job.file.path) {
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.setValue(range, forHTTPHeaderField: "Range")
            let (data, response) = try await api.session.data(for: request)
            try HoYoAPI.check(response, for: url)
            guard data.count == job.diff.length else {
                throw Failure(description: "diff for \(job.file.path) arrived short (\(data.count) of \(job.diff.length) bytes)")
            }
            return data
        }
        let diffFile = target.appendingPathExtension("sophon-diff")
        let staged = target.appendingPathExtension("sophon")
        defer {
            try? FileManager.default.removeItem(at: diffFile)
            try? FileManager.default.removeItem(at: staged)
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try diff.write(to: diffFile)
        do {
            try SophonCodec.patch(old: old, diff: diffFile, to: staged)
        } catch {
            return .failed
        }
        guard (try? SophonCodec.md5(of: staged)) == job.file.md5 else { return .failed }
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: target)
        }
        return .patched
    }

    private func retrying<T: Sendable>(_ what: String, _ body: () async throws -> T) async throws -> T {
        var last: any Error = Failure(description: "\(what): no attempt was made")
        for attempt in 0 ... backoff.count {
            do {
                return try await body()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                last = error
            }
            if attempt < backoff.count { try await Task.sleep(for: backoff[attempt]) }
        }
        throw last
    }

    /// Refuses a transfer without room plus a gigabyte of margin.
    static func requireSpace(_ bytes: Int64, at folder: URL) throws {
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return }
        let needed = bytes + (1 << 30)
        guard free >= needed else {
            let format = ByteCountFormatter()
            throw Failure(description: "needs \(format.string(fromByteCount: needed)) free, the disk has \(format.string(fromByteCount: free))")
        }
    }
}

/// How far an install, update or repair has come.
nonisolated struct SophonProgress: Sendable, Equatable {
    enum Phase: String, Sendable {
        case preparing
        case checking
        case downloading
        case patching
        case finishing
    }

    var phase: Phase
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var filesDone = 0
    var filesTotal = 0

    var fraction: Double? {
        if bytesTotal > 0 { return Double(bytesDone) / Double(bytesTotal) }
        if filesTotal > 0 { return Double(filesDone) / Double(filesTotal) }
        return nil
    }
}

/// Sums concurrent progress and reports it at most every 250 ms.
private actor Tally {
    private var progress: SophonProgress
    private let report: SophonDownloader.ProgressHandler
    private var lastReport = ContinuousClock.now

    init(phase: SophonProgress.Phase, bytesTotal: Int64, filesTotal: Int, report: @escaping SophonDownloader.ProgressHandler) {
        progress = SophonProgress(phase: phase, bytesTotal: bytesTotal, filesTotal: filesTotal)
        self.report = report
        report(progress)
    }

    func add(_ bytes: Int64) {
        progress.bytesDone += bytes
        maybeReport()
    }

    func fileDone() {
        progress.filesDone += 1
        maybeReport()
    }

    func flush() { report(progress) }

    private func maybeReport() {
        let now = ContinuousClock.now
        guard now - lastReport >= .milliseconds(250) else { return }
        lastReport = now
        report(progress)
    }
}

/// Files being written from chunks: a descriptor and the chunks to come.
private actor Assembly {
    private let folder: URL
    private var open: [String: (descriptor: Int32, remaining: Int)] = [:]

    init(folder: URL) { self.folder = folder }

    /// Writes one chunk; answers the staged file once complete.
    func write(_ data: Data, of chunk: SophonManifest.Chunk, into file: SophonManifest.File) throws -> URL? {
        let staged = folder.appending(path: file.path).appendingPathExtension("sophon")
        var entry = try open[file.path] ?? (descriptor: create(staged, size: file.size), remaining: file.chunks.count)
        let written = data.withUnsafeBytes { bytes in
            pwrite(entry.descriptor, bytes.baseAddress, bytes.count, off_t(chunk.offset))
        }
        guard written == data.count else {
            close(entry.descriptor)
            open[file.path] = nil
            throw SophonDownloader.Failure(description: "could not write \(file.path): \(String(cString: strerror(errno)))")
        }
        entry.remaining -= 1
        guard entry.remaining == 0 else {
            open[file.path] = entry
            return nil
        }
        close(entry.descriptor)
        open[file.path] = nil
        return staged
    }

    /// Places a file the manifest lists with no chunks: an empty file.
    func finishEmpty(_ file: SophonManifest.File) throws {
        let staged = folder.appending(path: file.path).appendingPathExtension("sophon")
        try close(create(staged, size: 0))
        try Self.place(staged, as: file, in: folder)
    }

    private func create(_ url: URL, size: Int64) throws -> Int32 {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else {
            throw SophonDownloader.Failure(description: "could not create \(url.path): \(String(cString: strerror(errno)))")
        }
        ftruncate(descriptor, off_t(size))
        return descriptor
    }

    /// Checks and places a finished file, off the actor so hashing blocks no
    /// chunks.
    nonisolated static func place(_ staged: URL, as file: SophonManifest.File, in folder: URL) throws {
        guard (try? SophonCodec.md5(of: staged)) == file.md5 else {
            try? FileManager.default.removeItem(at: staged)
            throw SophonDownloader.Failure(description: "\(file.path) does not match its checksum after download")
        }
        let target = folder.appending(path: file.path)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: target)
        }
    }
}

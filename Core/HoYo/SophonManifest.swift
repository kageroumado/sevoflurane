import Foundation

/// Every file of one category of a Sophon build, decoded from the protobuf
/// manifest `getBuild` points at.
///
/// Field numbers, read off the 4.6.0 Star Rail manifest with `protoc
/// --decode_raw` and checked by rebuilding files from them:
///
/// - manifest: `1` file (repeated)
/// - file: `1` path, `2` chunk (repeated), `3` type (64 for a directory),
///   `4` size, `5` md5
/// - chunk: `1` name on the server, `2` md5 of its decompressed bytes,
///   `3` offset in the file, `4` compressed size, `5` size, `7` md5 of the
///   compressed bytes
nonisolated struct SophonManifest: Sendable {
    struct Chunk: Sendable, Equatable {
        let name: String
        let md5: String
        let offset: Int64
        let compressedSize: Int64
        let size: Int64
        let compressedMD5: String
    }

    struct File: Sendable, Equatable {
        let path: String
        let size: Int64
        let md5: String
        let chunks: [Chunk]
    }

    let files: [File]

    init(files: [File]) { self.files = files }

    init(decoding data: Data) throws {
        var files: [File] = []
        for field in try ProtobufReader.fields(data) where field.number == 1 {
            var path = "", size: Int64 = 0, md5 = "", type: Int64 = 0
            var chunks: [Chunk] = []
            for part in try ProtobufReader.fields(field.bytes) {
                switch part.number {
                case 1: path = part.string
                case 2: try chunks.append(Self.chunk(part.bytes))
                case 3: type = part.integer
                case 4: size = part.integer
                case 5: md5 = part.string
                default: break
                }
            }
            if type == 64 { continue }
            files.append(File(path: path, size: size, md5: md5, chunks: chunks))
        }
        self.files = files
    }

    private static func chunk(_ data: Data) throws -> Chunk {
        var name = "", md5 = "", compressedMD5 = ""
        var offset: Int64 = 0, compressedSize: Int64 = 0, size: Int64 = 0
        for part in try ProtobufReader.fields(data) {
            switch part.number {
            case 1: name = part.string
            case 2: md5 = part.string
            case 3: offset = part.integer
            case 4: compressedSize = part.integer
            case 5: size = part.integer
            case 7: compressedMD5 = part.string
            default: break
            }
        }
        return Chunk(
            name: name, md5: md5, offset: offset, compressedSize: compressedSize, size: size,
            compressedMD5: compressedMD5,
        )
    }
}

/// What an update changes in one category, decoded from the protobuf
/// manifest `getPatchBuild` points at.
///
/// - manifest: `1` file (repeated), `2` deletions (repeated, one per tag)
/// - file: `1` path, `2` size, `3` md5, `4` patch (repeated, one per tag the
///   file changed since; a file with none is the same in every listed tag)
/// - patch: `1` tag, `2` diff
/// - diff: `1` blob name on the server, `4` blob size, `6` offset of this
///   diff in the blob, `7` its length, `8` the older file it applies to
///   (absent for a file that is new, whose diff applies to nothing),
///   `9` that file's size, `10` its md5
/// - deletions: `1` tag, `2` list, whose `1` entries are files with `1`
///   path, `2` size, `3` md5
///
/// Each diff is an HDiffPatch compressed diff (`HDIFF13&zstd`).
nonisolated struct SophonPatchManifest: Sendable {
    struct Diff: Sendable, Equatable {
        let blob: String
        let offset: Int64
        let length: Int64
        /// The older file the diff applies to, or nil for a new file.
        let original: String?
        let originalSize: Int64
        let originalMD5: String
    }

    struct File: Sendable, Equatable {
        let path: String
        let size: Int64
        let md5: String
        /// The diff to this file from each older tag it changed since.
        let diffs: [String: Diff]
    }

    struct Deleted: Sendable, Equatable {
        let path: String
        let size: Int64
        let md5: String
    }

    let files: [File]
    /// The files each older tag has that this build no longer does.
    let deletions: [String: [Deleted]]

    init(decoding data: Data) throws {
        var files: [File] = []
        var deletions: [String: [Deleted]] = [:]
        for field in try ProtobufReader.fields(data) {
            switch field.number {
            case 1: try files.append(Self.file(field.bytes))
            case 2:
                let (tag, list) = try Self.deletions(field.bytes)
                deletions[tag, default: []] += list
            default: break
            }
        }
        self.files = files
        self.deletions = deletions
    }

    private static func file(_ data: Data) throws -> File {
        var path = "", size: Int64 = 0, md5 = ""
        var diffs: [String: Diff] = [:]
        for part in try ProtobufReader.fields(data) {
            switch part.number {
            case 1: path = part.string
            case 2: size = part.integer
            case 3: md5 = part.string
            case 4:
                var tag = ""
                var diff: Diff?
                for entry in try ProtobufReader.fields(part.bytes) {
                    if entry.number == 1 { tag = entry.string }
                    if entry.number == 2 { diff = try Self.diff(entry.bytes) }
                }
                if let diff { diffs[tag] = diff }
            default: break
            }
        }
        return File(path: path, size: size, md5: md5, diffs: diffs)
    }

    private static func diff(_ data: Data) throws -> Diff {
        var blob = "", original: String?, originalMD5 = ""
        var offset: Int64 = 0, length: Int64 = 0, originalSize: Int64 = 0
        for part in try ProtobufReader.fields(data) {
            switch part.number {
            case 1: blob = part.string
            case 6: offset = part.integer
            case 7: length = part.integer
            case 8: original = part.string.isEmpty ? nil : part.string
            case 9: originalSize = part.integer
            case 10: originalMD5 = part.string
            default: break
            }
        }
        return Diff(
            blob: blob, offset: offset, length: length, original: original,
            originalSize: originalSize, originalMD5: originalMD5,
        )
    }

    private static func deletions(_ data: Data) throws -> (String, [Deleted]) {
        var tag = ""
        var deleted: [Deleted] = []
        for part in try ProtobufReader.fields(data) {
            if part.number == 1 { tag = part.string }
            guard part.number == 2 else { continue }
            for entry in try ProtobufReader.fields(part.bytes) where entry.number == 1 {
                var path = "", size: Int64 = 0, md5 = ""
                for item in try ProtobufReader.fields(entry.bytes) {
                    switch item.number {
                    case 1: path = item.string
                    case 2: size = item.integer
                    case 3: md5 = item.string
                    default: break
                    }
                }
                deleted.append(Deleted(path: path, size: size, md5: md5))
            }
        }
        return (tag, deleted)
    }
}

/// The protobuf wire format, as far as Sophon's manifests use it: varints
/// and length-delimited fields, read without a schema.
nonisolated enum ProtobufReader {
    struct Field {
        let number: Int
        /// The value of a varint field.
        let integer: Int64
        /// The payload of a length-delimited field.
        let bytes: Data

        var string: String { String(decoding: bytes, as: UTF8.self) }
    }

    struct Malformed: Error, CustomStringConvertible {
        let description: String
    }

    /// The top-level fields of one message, in order.
    static func fields(_ data: Data) throws -> [Field] {
        let bytes = [UInt8](data)
        var fields: [Field] = []
        var index = 0
        while index < bytes.count {
            let key = try varint(bytes, &index)
            let number = Int(key >> 3)
            switch key & 7 {
            case 0:
                let value = try varint(bytes, &index)
                fields.append(Field(number: number, integer: Int64(bitPattern: value), bytes: Data()))
            case 1:
                guard index + 8 <= bytes.count else { throw Malformed(description: "truncated fixed64") }
                index += 8
            case 2:
                let length = try Int(varint(bytes, &index))
                guard length >= 0, index + length <= bytes.count else {
                    throw Malformed(description: "field \(number) runs past the end")
                }
                fields.append(Field(number: number, integer: 0, bytes: Data(bytes[index ..< index + length])))
                index += length
            case 5:
                guard index + 4 <= bytes.count else { throw Malformed(description: "truncated fixed32") }
                index += 4
            default:
                throw Malformed(description: "wire type \(key & 7) at byte \(index)")
            }
        }
        return fields
    }

    private static func varint(_ bytes: [UInt8], _ index: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        throw Malformed(description: "truncated varint")
    }
}

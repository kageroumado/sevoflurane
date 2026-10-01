import Foundation
import SophonCodecs
import Testing
@testable import Sevoflurane

/// The codecs a Sophon download needs and the manifests it reads, against
/// fixtures made by HDiffPatch's own `hdiffz -c-zstd` and by `zstd -19`.
struct SophonCodecTests {
    /// Two hundred numbered lines: the older file of the diff fixtures.
    static let oldText = (0 ..< 200).map { "line \($0): the quick brown fox \($0 * 37 % 1000)\n" }.joined()

    /// The newer file: two lines reworded and one appended.
    static let newText = oldText
        .replacingOccurrences(of: "line 50:", with: "LINE FIFTY:")
        .replacingOccurrences(of: "line 150:", with: "changed 150:")
        + "a tail the old file never had\n"

    /// `hdiffz -c-zstd old new`.
    static let diff = Data(base64Encoded: "SERJRkYxMyZ6c3RkALQ0tBADDAADAAAALwAAAIxiBwqaBwQHjRwgtDNMSU5FIEZJRlRZY2hhbmdlZGEgdGFpbCB0aGUgb2xkIGZpbGUgbmV2ZXIgaGFkCg==")!

    /// `hdiffz -c-zstd <empty file> new`: how a diff carries a new file.
    static let diffFromNothing = Data(base64Encoded: "SERJRkYxMyZ6c3RkALQ0AAAAAAMAAAC0NIUbILQzKLUv/WA0GY0UAPbxahpgV7UBT1+1FMUJ4C/QYdEypeTKzQoIRCpdAWoAXQBcAAUARN/Opxs5q9VjxVN1jqVYiuom5dsNkfV1izNUnisKKUR3I/83Zp3XLpaKnjtKyZDczfyxm1tbs0VT1ZwU5YREdLvfmxmr6yqSVDdHBBDHBkWDY0KDwkLBEbEAgVHheDxcOALE8ZiAkAgUkkeS8Bf2wrnQFpaFtPBOSCeUE5p97O7bs7961aVudKJ/3DHHposW+kz+bff87CsffXdHd3JndmP3XmusXVmVSZmREdnHOjZjZosV9kr9a++8dotwMEAw4BAwIAhkl+VSXN6VdOWtNCvHSreslA6Gh8NEwsMCALHFqyJVUapoVBwqfoqdIqdoFotEId2IRPyJPXFOtIllIk28G9INb0Oz4djQHbZDdng1rBpKkUbkEPkhOySHNMkiAwAMCQ8Oi0fGY8LxkIBocDBIUEhAJFw4EgDIfhvy7/vUXk7vq7PoJZyf8UJy+m21z5/H5lZtcZlHLrrxnRYT09jP7HvdDWvX65nqKEVXNndDPLkc9WYc2+9syqzCmq2MRFYfu9JkLhaBjagRENnWqdFuoS+qPBEkDF7473yCE+tIETOCSG/YFn9fiIj1foRC8kiJnL35i1Ak7UT1Stgacq9bfoAEAYJbSxWgDEK7hAgIEGBQupklIECAgAAB4pAeYECAgACY3sZVTatYVbpUa6a0StVF1YSq9aTrtISoTCg2GhSVCRUpEiGXYMGETCfUpEhMqESbJpEJFSkSEyqLiTRKO8nWE1hN0TMUpTh5qdLzvvwzTqNjFknn+8p9vUmOgn1OGg0PAMWnMgyLct190nNXpNxAnFt7WyptV6rLNQ3XXpFV2NoWDEBaBQ==")!

    /// `zstd -19 new`.
    static let compressed = Data(base64Encoded: "KLUv/WQ0GY0UAPbxahpgV7UBT1+1FMUJ4C/QYdEypeTKzQoIRCpdAWoAXQBcAAUARN/Opxs5q9VjxVN1jqVYiuom5dsNkfV1izNUnisKKUR3I/83Zp3XLpaKnjtKyZDczfyxm1tbs0VT1ZwU5YREdLvfmxmr6yqSVDdHBBDHBkWDY0KDwkLBEbEAgVHheDxcOALE8ZiAkAgUkkeS8Bf2wrnQFpaFtPBOSCeUE5p97O7bs7961aVudKJ/3DHHposW+kz+bff87CsffXdHd3JndmP3XmusXVmVSZmREdnHOjZjZosV9kr9a++8dotwMEAw4BAwIAhkl+VSXN6VdOWtNCvHSreslA6Gh8NEwsMCALHFqyJVUapoVBwqfoqdIqdoFotEId2IRPyJPXFOtIllIk28G9INb0Oz4djQHbZDdng1rBpKkUbkEPkhOySHNMkiAwAMCQ8Oi0fGY8LxkIBocDBIUEhAJFw4EgDIfhvy7/vUXk7vq7PoJZyf8UJy+m21z5/H5lZtcZlHLrrxnRYT09jP7HvdDWvX65nqKEVXNndDPLkc9WYc2+9syqzCmq2MRFYfu9JkLhaBjagRENnWqdFuoS+qPBEkDF7473yCE+tIETOCSG/YFn9fiIj1foRC8kiJnL35i1Ak7UT1Stgacq9bfoAEAYJbSxWgDEK7hAgIEGBQupklIECAgAAB4pAeYECAgACY3sZVTatYVbpUa6a0StVF1YSq9aTrtISoTCg2GhSVCRUpEiGXYMGETCfUpEhMqESbJpEJFSkSEyqLiTRKO8nWE1hN0TMUpTh5qdLzvvwzTqNjFknn+8p9vUmOgn1OGg0PAMWnMgyLct190nNXpNxAnFt7WyptV6rLNQ3XXpFV2NoWDEBaBWyH3i4=")!

    static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "sophon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Codecs

    @Test
    func `a zstd frame decompresses to the size it is listed at`() throws {
        let data = try SophonCodec.decompress(Self.compressed, expectedSize: Self.newText.utf8.count)
        #expect(String(decoding: data, as: UTF8.self) == Self.newText)
    }

    @Test
    func `a zstd frame of another size is refused`() {
        #expect(throws: (any Error).self) {
            try SophonCodec.decompress(Self.compressed, expectedSize: 10)
        }
    }

    @Test
    func `a diff turns the older file into the newer one`() throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appending(path: "old"), diff = folder.appending(path: "diff"), new = folder.appending(path: "new")
        try Data(Self.oldText.utf8).write(to: old)
        try Self.diff.write(to: diff)
        try SophonCodec.patch(old: old, diff: diff, to: new)
        #expect(try String(contentsOf: new, encoding: .utf8) == Self.newText)
        #expect(try SophonCodec.md5(of: new) == SophonCodec.md5(Data(Self.newText.utf8)))
    }

    @Test
    func `a diff from nothing creates the file`() throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let diff = folder.appending(path: "diff"), new = folder.appending(path: "new")
        try Self.diffFromNothing.write(to: diff)
        try SophonCodec.patch(old: nil, diff: diff, to: new)
        #expect(try String(contentsOf: new, encoding: .utf8) == Self.newText)
    }

    @Test
    func `a diff is refused against a file of the wrong size`() throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appending(path: "old"), diff = folder.appending(path: "diff")
        try Data("not the old file".utf8).write(to: old)
        try Self.diff.write(to: diff)
        #expect(throws: SophonCodec.PatchFailure.oldSize) {
            try SophonCodec.patch(old: old, diff: diff, to: folder.appending(path: "new"))
        }
    }

    @Test
    func `bytes that are not a diff are refused`() throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let diff = folder.appending(path: "diff")
        try Data("HDIFF? no".utf8).write(to: diff)
        #expect(throws: SophonCodec.PatchFailure.badDiff) {
            try SophonCodec.patch(old: nil, diff: diff, to: folder.appending(path: "new"))
        }
    }

    // MARK: - Manifests

    @Test
    func `a build manifest lists each file with its chunks and skips directories`() throws {
        let chunk = Proto.message([
            Proto.field(1, "0a_chunk"), Proto.field(2, "decompressedmd5"), Proto.field(3, 1024),
            Proto.field(4, 300), Proto.field(5, 900), Proto.field(6, 12345), Proto.field(7, "compressedmd5"),
        ])
        let file = Proto.message([
            Proto.field(1, "StarRail_Data/a.block"), Proto.field(2, chunk), Proto.field(4, 1924), Proto.field(5, "filemd5"),
        ])
        let directory = Proto.message([Proto.field(1, "StarRail_Data"), Proto.field(3, 64)])
        let manifest = try SophonManifest(decoding: Proto.message([Proto.field(1, file), Proto.field(1, directory)]))
        #expect(manifest.files == [
            .init(path: "StarRail_Data/a.block", size: 1924, md5: "filemd5", chunks: [
                .init(name: "0a_chunk", md5: "decompressedmd5", offset: 1024, compressedSize: 300, size: 900, compressedMD5: "compressedmd5"),
            ]),
        ])
    }

    @Test
    func `a patch manifest keys each diff by the tag it starts from`() throws {
        let changed = Proto.message([
            Proto.field(1, "b.block"), Proto.field(2, 70), Proto.field(3, "newmd5"),
            Proto.field(4, Proto.message([
                Proto.field(1, "4.5.0"),
                Proto.field(2, Proto.message([
                    Proto.field(1, "blob_1"), Proto.field(2, "4.5.0"), Proto.field(4, 5000), Proto.field(5, "blobmd5"),
                    Proto.field(6, 100), Proto.field(7, 88), Proto.field(8, "b.block"), Proto.field(9, 66), Proto.field(10, "oldmd5"),
                ])),
            ])),
        ])
        let created = Proto.message([
            Proto.field(1, "c.block"), Proto.field(2, 5), Proto.field(3, "cmd5"),
            Proto.field(4, Proto.message([
                Proto.field(1, "4.5.0"),
                Proto.field(2, Proto.message([Proto.field(1, "blob_1"), Proto.field(6, 188), Proto.field(7, 40)])),
            ])),
        ])
        let unchanged = Proto.message([Proto.field(1, "d.block"), Proto.field(2, 9), Proto.field(3, "dmd5")])
        let deletions = Proto.message([
            Proto.field(1, "4.5.0"),
            Proto.field(2, Proto.message([
                Proto.field(1, Proto.message([Proto.field(1, "gone.block"), Proto.field(2, 3), Proto.field(3, "gonemd5")])),
            ])),
        ])
        let manifest = try SophonPatchManifest(decoding: Proto.message([
            Proto.field(1, changed), Proto.field(1, created), Proto.field(1, unchanged), Proto.field(2, deletions),
        ]))
        #expect(manifest.files.count == 3)
        #expect(manifest.files[0].diffs["4.5.0"] == .init(
            blob: "blob_1", offset: 100, length: 88, original: "b.block", originalSize: 66, originalMD5: "oldmd5",
        ))
        #expect(manifest.files[1].diffs["4.5.0"]?.original == nil)
        #expect(manifest.files[2].diffs.isEmpty)
        #expect(manifest.deletions["4.5.0"] == [.init(path: "gone.block", size: 3, md5: "gonemd5")])
    }

    @Test(arguments: ["", "/etc/hosts", "../escape.block", "StarRail_Data/../../escape.block"])
    func `a manifest path outside the game folder is refused`(path: String) {
        let file = Proto.message([Proto.field(1, path), Proto.field(4, 10)])
        #expect(throws: ProtobufReader.Malformed.self) {
            try SophonManifest(decoding: Proto.message([Proto.field(1, file)]))
        }
        let deletions = Proto.message([
            Proto.field(1, "4.5.0"),
            Proto.field(2, Proto.message([Proto.field(1, Proto.message([Proto.field(1, path)]))])),
        ])
        #expect(throws: ProtobufReader.Malformed.self) {
            try SophonPatchManifest(decoding: Proto.message([Proto.field(2, deletions)]))
        }
        let patched = Proto.message([
            Proto.field(1, "b.block"),
            Proto.field(4, Proto.message([
                Proto.field(1, "4.5.0"),
                Proto.field(2, Proto.message([Proto.field(1, "blob_1"), Proto.field(8, path)])),
            ])),
        ])
        if !path.isEmpty {
            #expect(throws: ProtobufReader.Malformed.self) {
                try SophonPatchManifest(decoding: Proto.message([Proto.field(1, patched)]))
            }
        }
    }

    @Test
    func `a truncated manifest is refused`() {
        let file = Proto.message([Proto.field(1, "a.block"), Proto.field(4, 10)])
        let whole = Proto.message([Proto.field(1, file)])
        #expect(throws: (any Error).self) {
            try SophonManifest(decoding: whole.prefix(whole.count - 2))
        }
    }
}

/// Protobuf's wire format, written: enough to build the manifests above.
enum Proto {
    static func varint(_ value: UInt64) -> Data {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return Data(bytes)
    }

    static func field(_ number: Int, _ value: Int64) -> Data {
        varint(UInt64(number << 3)) + varint(UInt64(bitPattern: value))
    }

    static func field(_ number: Int, _ text: String) -> Data { field(number, Data(text.utf8)) }

    static func field(_ number: Int, _ bytes: Data) -> Data {
        varint(UInt64(number << 3 | 2)) + varint(UInt64(bytes.count)) + bytes
    }

    static func message(_ fields: [Data]) -> Data { fields.reduce(Data(), +) }
}

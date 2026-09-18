import CoreGraphics
import Foundation
import ImageIO

/// What a Windows executable says about itself: the icons in its resource
/// section, the strings in its version resource, and the privilege its
/// embedded manifest asks Windows for.
///
/// A PE image keeps all three in one tree hanging off the optional header's
/// resource data directory, three levels deep — type, name, language — with a
/// leaf that names a range by relative virtual address. Reading it takes no
/// Wine and no bottle, so the app can describe a program before it has ever
/// run one, and the Quick Look extension can draw its icon inside the sandbox.
///
/// The icon group is walked the way `macdrv_app_icon` walks it in the Mac
/// driver: the lowest-numbered `RT_GROUP_ICON` names the images that make up
/// the application icon, and each named `RT_ICON` is a PNG or a Windows DIB
/// with an AND mask under it.
nonisolated enum PEResources {
    /// One image out of the file's icon group, at its own size.
    struct Icon: Sendable, Equatable {
        /// Side in pixels; a Windows icon is square.
        let pixels: Int
        /// Whether the bytes are a PNG rather than a DIB with an AND mask.
        let isPNG: Bool
        let data: Data
    }

    /// Everything one executable was asked for.
    struct Info: Sendable, Equatable {
        var icons: [Icon] = []
        /// The `StringFileInfo` table of `VS_VERSIONINFO`, by key.
        var versionStrings: [String: String] = [:]
        /// The manifest's `requestedExecutionLevel`, such as
        /// `requireAdministrator`.
        var requestedExecutionLevel: String?

        var productName: String? {
            versionStrings["ProductName"]
        }
        var fileDescription: String? {
            versionStrings["FileDescription"]
        }
        var fileVersion: String? {
            versionStrings["FileVersion"]
        }
        /// The version the product declares, falling back to the file's own —
        /// the two differ only where a build stamps them separately.
        var productVersion: String? {
            versionStrings["ProductVersion"] ?? fileVersion
        }
        var companyName: String? {
            versionStrings["CompanyName"]
        }

        /// The image worth drawing: the widest, and the PNG of two at the
        /// same width, whose compressed form carries the 8-bit alpha the DIB
        /// beside it usually flattens.
        var largestIcon: Icon? {
            icons.max { first, second in
                first.pixels == second.pixels
                    ? (!first.isPNG && second.isPNG)
                    : first.pixels < second.pixels
            }
        }
    }

    /// Reads one executable. `nil` when the file is not a PE image at all;
    /// an image with no resource section reads as an empty ``Info``.
    static func read(_ url: URL) -> Info? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let sections = sections(of: data) else { return nil }
        guard let root = resourceRoot(of: data, sections: sections) else { return Info() }
        var info = Info()
        info.icons = icons(in: data, root: root, sections: sections)
        if let block = firstResource(
            ofType: Kind.version, in: data, root: root, sections: sections,
        ) {
            info.versionStrings = versionStrings(in: block)
        }
        if let manifest = firstResource(
            ofType: Kind.manifest, in: data, root: root, sections: sections,
        ) {
            info.requestedExecutionLevel = executionLevel(in: manifest)
        }
        return info
    }

    /// Whether the file carries the two signatures every PE image has.
    static func isExecutable(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 0x40), head.count == 0x40,
              u16(head, 0) == 0x5A4D, let peOffset = u32(head, 0x3C) else { return false }
        guard (try? handle.seek(toOffset: UInt64(peOffset))) != nil,
              let signature = try? handle.read(upToCount: 4) else { return false }
        return u32(signature, 0) == 0x0000_4550
    }

    /// The icon as Core Graphics sees it, decoding a PNG entry through
    /// ImageIO and a DIB entry by hand.
    static func image(of icon: Icon) -> CGImage? {
        if icon.isPNG {
            guard let source = CGImageSourceCreateWithData(icon.data as CFData, nil) else {
                return nil
            }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        return dibImage(icon.data)
    }

    /// The file's own application icon, ready to draw.
    static func icon(at url: URL) -> CGImage? {
        guard let largest = read(url)?.largestIcon else { return nil }
        return image(of: largest)
    }

    // MARK: - The image's shape

    /// Resource type ids, as Windows numbers them.
    private enum Kind {
        static let icon = 3
        static let groupIcon = 14
        static let version = 16
        static let manifest = 24
    }

    /// One section of the image, which is what turns a relative virtual
    /// address into a file offset.
    private struct Section {
        let virtualAddress: Int
        let virtualSize: Int
        let rawOffset: Int
        let rawSize: Int
    }

    /// The section table. Its position needs only `SizeOfOptionalHeader`,
    /// which sits in the same place in PE32 and PE32+.
    private static func sections(of data: Data) -> [Section]? {
        guard u16(data, 0) == 0x5A4D, let peOffset = u32(data, 0x3C),
              u32(data, peOffset) == 0x0000_4550,
              let count = u16(data, peOffset + 4 + 2),
              let optionalSize = u16(data, peOffset + 4 + 16) else { return nil }
        let table = peOffset + 4 + 20 + optionalSize
        var result: [Section] = []
        for index in 0 ..< count {
            let entry = table + index * 40
            guard let virtualSize = u32(data, entry + 8),
                  let virtualAddress = u32(data, entry + 12),
                  let rawSize = u32(data, entry + 16),
                  let rawOffset = u32(data, entry + 20) else { return nil }
            result.append(Section(
                virtualAddress: virtualAddress, virtualSize: virtualSize,
                rawOffset: rawOffset, rawSize: rawSize,
            ))
        }
        return result
    }

    private static func fileOffset(of rva: Int, in sections: [Section]) -> Int? {
        for section in sections {
            let span = max(section.virtualSize, section.rawSize)
            guard rva >= section.virtualAddress, rva < section.virtualAddress + span else {
                continue
            }
            return section.rawOffset + (rva - section.virtualAddress)
        }
        return nil
    }

    /// The resource tree's root, from data directory entry 2. The directory
    /// array starts 96 bytes into a PE32 optional header and 112 into a
    /// PE32+ one, which is the only place the two shapes differ here.
    private static func resourceRoot(of data: Data, sections: [Section]) -> Int? {
        guard let peOffset = u32(data, 0x3C) else { return nil }
        let optional = peOffset + 4 + 20
        guard let magic = u16(data, optional) else { return nil }
        let directories = optional + (magic == 0x20B ? 112 : 96)
        guard let rva = u32(data, directories + 16), rva != 0 else { return nil }
        return fileOffset(of: rva, in: sections)
    }

    // MARK: - The resource tree

    private struct Node {
        /// The entry's numeric id; a named entry carries `nil`.
        let id: Int?
        let isDirectory: Bool
        /// Where the child directory or the leaf sits, relative to the root.
        let offset: Int
    }

    private static func children(of data: Data, at offset: Int) -> [Node] {
        guard let named = u16(data, offset + 12), let numbered = u16(data, offset + 14) else {
            return []
        }
        var result: [Node] = []
        for index in 0 ..< (named + numbered) {
            let entry = offset + 16 + index * 8
            guard let name = u32(data, entry), let value = u32(data, entry + 4) else { break }
            result.append(Node(
                id: name & 0x8000_0000 == 0 ? name : nil,
                isDirectory: value & 0x8000_0000 != 0,
                offset: value & 0x7FFF_FFFF,
            ))
        }
        return result
    }

    /// The bytes a leaf names, which it does by relative virtual address.
    private static func leaf(
        of data: Data, root: Int, offset: Int, sections: [Section],
    ) -> Data? {
        let entry = root + offset
        guard let rva = u32(data, entry), let size = u32(data, entry + 4), size > 0,
              let start = fileOffset(of: rva, in: sections),
              start >= 0, start + size <= data.count else { return nil }
        let base = data.startIndex
        return data.subdata(in: (base + start) ..< (base + start + size))
    }

    /// Every resource of one type, keyed by its resource id, taking the first
    /// language of each.
    private static func resources(
        ofType type: Int, in data: Data, root: Int, sections: [Section],
    ) -> [Int: Data] {
        guard let types = children(of: data, at: root).first(where: { $0.id == type }),
              types.isDirectory else { return [:] }
        var result: [Int: Data] = [:]
        for name in children(of: data, at: root + types.offset) {
            guard let id = name.id else { continue }
            let leafNode = name.isDirectory
                ? children(of: data, at: root + name.offset).first
                : name
            guard let leafNode, let bytes = leaf(
                of: data, root: root, offset: leafNode.offset, sections: sections,
            ) else { continue }
            result[id] = bytes
        }
        return result
    }

    private static func firstResource(
        ofType type: Int, in data: Data, root: Int, sections: [Section],
    ) -> Data? {
        resources(ofType: type, in: data, root: root, sections: sections)
            .min { $0.key < $1.key }?.value
    }

    // MARK: - Icons

    /// The images of the lowest-numbered icon group, which is the one
    /// Windows shows for the program.
    private static func icons(in data: Data, root: Int, sections: [Section]) -> [Icon] {
        guard let group = firstResource(
            ofType: Kind.groupIcon, in: data, root: root, sections: sections,
        ) else { return [] }
        let images = resources(ofType: Kind.icon, in: data, root: root, sections: sections)
        guard let count = u16(group, 4) else { return [] }
        var result: [Icon] = []
        for index in 0 ..< count {
            let entry = 6 + index * 14
            guard let width = u8(group, entry), let id = u16(group, entry + 12),
                  let bytes = images[id] else { continue }
            let isPNG = bytes.count > 8 && u32(bytes, 0) == 0x474E_5089
            // A zero width is how the directory spells 256, the largest size
            // its one-byte field can name.
            result.append(Icon(pixels: width == 0 ? 256 : width, isPNG: isPNG, data: bytes))
        }
        return result
    }

    /// A DIB icon: a `BITMAPINFOHEADER` whose height counts the color rows
    /// and the mask rows together, bottom-up color rows padded to four bytes,
    /// then a one-bit AND mask padded the same way.
    private static func dibImage(_ dib: Data) -> CGImage? {
        guard let headerSize = u32(dib, 0), headerSize >= 40,
              let width = u32(dib, 4), let stacked = u32(dib, 8),
              let bitCount = u16(dib, 14), let compression = u32(dib, 16),
              compression == 0, width > 0, width <= 1024 else { return nil }
        let height = stacked / 2
        guard height > 0, height <= 1024 else { return nil }
        let palette = paletteEntries(bitCount: bitCount, declared: u32(dib, 32) ?? 0)
        let colorStart = headerSize + palette * 4
        let colorRow = ((width * bitCount + 31) / 32) * 4
        let maskStart = colorStart + colorRow * height
        let maskRow = ((width + 31) / 32) * 4
        guard maskStart + maskRow * height <= dib.count else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let carriesAlpha = bitCount == 32
            && hasAlpha(dib, start: colorStart, count: colorRow * height)
        for row in 0 ..< height {
            // Bottom-up: the first stored row is the image's last one.
            let source = colorStart + (height - 1 - row) * colorRow
            let mask = maskStart + (height - 1 - row) * maskRow
            for column in 0 ..< width {
                guard let color = pixel(
                    dib, row: source, column: column, bitCount: bitCount,
                    paletteStart: headerSize, palette: palette,
                ) else { continue }
                let alpha = carriesAlpha
                    ? color.alpha
                    : (maskBit(dib, row: mask, column: column) ? 0 : 255)
                let out = (row * width + column) * 4
                pixels[out] = premultiplied(color.red, alpha)
                pixels[out + 1] = premultiplied(color.green, alpha)
                pixels[out + 2] = premultiplied(color.blue, alpha)
                pixels[out + 3] = alpha
            }
        }
        return bitmap(pixels, width: width, height: height)
    }

    /// How many palette entries sit between the header and the pixels: what
    /// the header declares, or the whole table the depth implies.
    private static func paletteEntries(bitCount: Int, declared: Int) -> Int {
        guard bitCount <= 8 else { return 0 }
        return declared > 0 ? declared : 1 << bitCount
    }

    /// Whether a 32-bit image's alpha channel says anything. An icon whose
    /// every alpha byte is zero stores its shape in the AND mask instead.
    private static func hasAlpha(_ dib: Data, start: Int, count: Int) -> Bool {
        var offset = start + 3
        let end = min(start + count, dib.count)
        while offset < end {
            if dib[dib.startIndex + offset] != 0 { return true }
            offset += 4
        }
        return false
    }

    private struct Color {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8
    }

    /// One pixel of a color row, resolved through the palette where the
    /// depth calls for one.
    private static func pixel(
        _ dib: Data, row: Int, column: Int, bitCount: Int, paletteStart: Int, palette: Int,
    ) -> Color? {
        switch bitCount {
        case 32, 24:
            let stride = bitCount / 8
            guard let blue = u8(dib, row + column * stride),
                  let green = u8(dib, row + column * stride + 1),
                  let red = u8(dib, row + column * stride + 2) else { return nil }
            let alpha = bitCount == 32 ? (u8(dib, row + column * 4 + 3) ?? 255) : 255
            return Color(
                red: UInt8(red), green: UInt8(green), blue: UInt8(blue), alpha: UInt8(alpha),
            )
        case 8, 4:
            guard let index = paletteIndex(dib, row: row, column: column, bitCount: bitCount),
                  index < palette else { return nil }
            let entry = paletteStart + index * 4
            guard let blue = u8(dib, entry), let green = u8(dib, entry + 1),
                  let red = u8(dib, entry + 2) else { return nil }
            return Color(red: UInt8(red), green: UInt8(green), blue: UInt8(blue), alpha: 255)
        default:
            return nil
        }
    }

    private static func paletteIndex(
        _ dib: Data, row: Int, column: Int, bitCount: Int,
    ) -> Int? {
        if bitCount == 8 { return u8(dib, row + column) }
        guard let byte = u8(dib, row + column / 2) else { return nil }
        return column % 2 == 0 ? byte >> 4 : byte & 0x0F
    }

    /// The AND mask's bit for a column: set means the pixel is transparent.
    private static func maskBit(_ dib: Data, row: Int, column: Int) -> Bool {
        guard let byte = u8(dib, row + column / 8) else { return true }
        return (byte >> (7 - column % 8)) & 1 == 1
    }

    private static func premultiplied(_ channel: UInt8, _ alpha: UInt8) -> UInt8 {
        alpha == 255 ? channel : UInt8(Int(channel) * Int(alpha) / 255)
    }

    private static func bitmap(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent,
        )
    }

    // MARK: - Version strings

    /// One node of `VS_VERSIONINFO`: a length, a UTF-16 key, a value, and
    /// children packed behind the value on four-byte boundaries.
    private struct VersionNode {
        let key: String
        let value: String
        let childrenStart: Int
        let end: Int
    }

    private static func versionNode(in block: Data, at offset: Int) -> VersionNode? {
        guard let length = u16(block, offset), length >= 6,
              offset + length <= block.count,
              let valueLength = u16(block, offset + 2),
              let type = u16(block, offset + 4) else { return nil }
        let (key, afterKey) = utf16String(block, at: offset + 6)
        let valueStart = aligned(afterKey)
        let valueBytes = type == 1 ? valueLength * 2 : valueLength
        let value = type == 1 && valueLength > 0
            ? utf16String(block, at: valueStart, units: valueLength) : ""
        return VersionNode(
            key: key, value: value,
            childrenStart: aligned(valueStart + valueBytes), end: offset + length,
        )
    }

    private static func versionChildren(of node: VersionNode, in block: Data) -> [VersionNode] {
        var result: [VersionNode] = []
        var cursor = node.childrenStart
        while cursor < node.end, let child = versionNode(in: block, at: cursor) {
            guard child.end > cursor else { break }
            result.append(child)
            cursor = aligned(child.end)
        }
        return result
    }

    /// Every string of every table in the block's `StringFileInfo`.
    private static func versionStrings(in block: Data) -> [String: String] {
        guard let root = versionNode(in: block, at: 0) else { return [:] }
        var result: [String: String] = [:]
        for info in versionChildren(of: root, in: block) where info.key == "StringFileInfo" {
            for table in versionChildren(of: info, in: block) {
                for entry in versionChildren(of: table, in: block) where !entry.value.isEmpty {
                    result[entry.key] = entry.value
                }
            }
        }
        return result
    }

    /// A null-terminated UTF-16 run, and the offset just past its terminator.
    private static func utf16String(_ data: Data, at offset: Int) -> (String, Int) {
        var units: [UInt16] = []
        var cursor = offset
        while let unit = u16(data, cursor) {
            cursor += 2
            if unit == 0 { break }
            units.append(UInt16(unit))
        }
        return (String(decoding: units, as: UTF16.self), cursor)
    }

    /// A UTF-16 run of a known length in code units, terminator dropped.
    private static func utf16String(_ data: Data, at offset: Int, units count: Int) -> String {
        var units: [UInt16] = []
        for index in 0 ..< count {
            guard let unit = u16(data, offset + index * 2), unit != 0 else { break }
            units.append(UInt16(unit))
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func aligned(_ offset: Int) -> Int {
        (offset + 3) & ~3
    }

    // MARK: - Manifest

    /// The level the manifest asks Windows for, which is what marks a program
    /// that expects to be elevated.
    private static func executionLevel(in manifest: Data) -> String? {
        let text = String(decoding: manifest, as: UTF8.self)
        guard let key = text.range(of: "requestedExecutionLevel") else { return nil }
        let rest = text[key.upperBound...]
        guard let attribute = rest.range(of: "level=") else { return nil }
        let value = rest[attribute.upperBound...]
            .drop { $0 == "\"" || $0 == "'" || $0 == " " }
            .prefix { $0 != "\"" && $0 != "'" }
        return value.isEmpty ? nil : String(value)
    }

    // MARK: - Little-endian reads

    private static func u8(_ data: Data, _ offset: Int) -> Int? {
        guard offset >= 0, offset < data.count else { return nil }
        return Int(data[data.startIndex + offset])
    }

    private static func u16(_ data: Data, _ offset: Int) -> Int? {
        guard let low = u8(data, offset), let high = u8(data, offset + 1) else { return nil }
        return low | (high << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> Int? {
        guard let low = u16(data, offset), let high = u16(data, offset + 2) else { return nil }
        return low | (high << 16)
    }
}

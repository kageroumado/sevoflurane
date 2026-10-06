import Foundation

/// The client's own cache of every app's store data, `appcache/appinfo.vdf`,
/// read for what the client's API leaves out.
///
/// `GetLaunchOptionsForApp` answers a generic token (`#Steam_LaunchOption_Game`)
/// for options whose real names live here, under the app's `config/launch/<n>`:
/// Megabonk's two options are "Megabonk (DX11 - Recommended)" and "Megabonk
/// (DX12 - Use only if game crashes)" in this file and the same token twice
/// from the client.
///
/// The file is binary: a header, then one entry per app (id, size, a fixed
/// block of hashes and stamps, then the app's key-values in Valve's binary
/// KeyValues). Version 29 names keys by index into a string table at the end
/// of the file; version 28 writes each key inline.
nonisolated enum SteamAppInfo {
    /// The client's cache inside the Steam bottle.
    static var fileURL: URL {
        SteamBottle.steamRoot.appendingPathComponent("appcache/appinfo.vdf")
    }

    /// Each launch option's own description, by its key under `config/launch`,
    /// which is the `nIndex` the client numbers the option by. Empty when the
    /// file, the app, or its launch section is missing.
    static func launchDescriptions(appID: Int, in url: URL = fileURL) -> [Int: String] {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let app = keyValues(appID: appID, in: data),
              case let .table(config)? = app["config"], case let .table(launch)? = config["launch"]
        else { return [:] }
        var descriptions: [Int: String] = [:]
        for (key, value) in launch {
            guard let index = Int(key), case let .table(option) = value,
                  case let .string(description)? = option["description"], !description.isEmpty
            else { continue }
            descriptions[index] = description
        }
        return descriptions
    }

    /// The platforms Steam sells the game for (`common/oslist`: `windows`,
    /// `macos`, `linux`). Empty when the file or the app is missing.
    static func platforms(appID: Int, in url: URL = fileURL) -> Set<String> {
        platforms(appIDs: [appID], in: url)[appID] ?? []
    }

    /// ``platforms(appID:in:)`` for many apps in one pass over the file, the
    /// way a whole library asks. Apps the file lacks are absent.
    static func platforms(appIDs: Set<Int>, in url: URL = fileURL) -> [Int: Set<String>] {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return [:] }
        return keyValues(appIDs: appIDs, in: data).mapValues { app in
            guard case let .table(common)? = app["common"], case let .string(list)? = common["oslist"] else { return [] }
            return Set(list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        }
    }

    /// A binary KeyValues value.
    enum Value: Equatable {
        case table([String: Value])
        case string(String)
        case number(Int64)
    }

    // MARK: - Reading

    private static let version28: UInt32 = 0x0756_4428
    private static let version29: UInt32 = 0x0756_4429
    /// What sits between an entry's size and its key-values: info state,
    /// last update, PICS token, text SHA-1, change number, binary SHA-1.
    private static let entryPreamble = 4 + 4 + 8 + 20 + 4 + 20

    /// One app's key-values, the `appinfo` table's contents, or `nil` when the
    /// app is not in the file or the file is not one this reads.
    static func keyValues(appID: Int, in data: Data) -> [String: Value]? {
        keyValues(appIDs: [appID], in: data)[appID]
    }

    /// The key-values of every app in `appIDs` the file holds, read in one
    /// walk: the string table is parsed once and the walk stops when the last
    /// wanted app is found.
    static func keyValues(appIDs: Set<Int>, in data: Data) -> [Int: [String: Value]] {
        var reader = Reader(data: data)
        guard let magic = reader.u32(), magic == version28 || magic == version29,
              reader.u32() != nil else { return [:] }
        var strings: [String]?
        if magic == version29 {
            guard let offset = reader.i64(), offset > 0, offset < Int64(data.count) else { return [:] }
            var table = Reader(data: data, position: Int(offset))
            strings = table.stringTable()
            guard strings != nil else { return [:] }
        }
        var found: [Int: [String: Value]] = [:]
        while found.count < appIDs.count, let id = reader.u32(), id != 0 {
            guard let size = reader.u32() else { break }
            let next = reader.position + Int(size)
            guard next <= data.count else { break }
            if appIDs.contains(Int(id)) {
                reader.position += entryPreamble
                if let root = reader.table(strings: strings) {
                    if case let .table(appinfo)? = root["appinfo"] {
                        found[Int(id)] = appinfo
                    } else {
                        found[Int(id)] = root
                    }
                }
            }
            reader.position = next
        }
        return found
    }

    private struct Reader {
        let data: Data
        var position = 0

        init(data: Data, position: Int = 0) {
            self.data = data
            self.position = position
        }

        mutating func u8() -> UInt8? {
            guard position < data.count else { return nil }
            defer { position += 1 }
            return data[data.startIndex + position]
        }

        mutating func u32() -> UInt32? {
            integer(UInt32.self)
        }

        mutating func i64() -> Int64? {
            integer(Int64.self)
        }

        private mutating func integer<T: FixedWidthInteger>(_: T.Type) -> T? {
            let width = MemoryLayout<T>.size
            guard position + width <= data.count else { return nil }
            var value: T = 0
            for byte in 0 ..< width {
                value |= T(data[data.startIndex + position + byte]) << (8 * byte)
            }
            position += width
            return value
        }

        mutating func cString() -> String? {
            let start = data.startIndex + position
            guard let end = data[start...].firstIndex(of: 0) else { return nil }
            position = end - data.startIndex + 1
            return String(decoding: data[start ..< end], as: UTF8.self)
        }

        mutating func stringTable() -> [String]? {
            guard let count = u32() else { return nil }
            var strings: [String] = []
            strings.reserveCapacity(Int(count))
            for _ in 0 ..< count {
                guard let string = cString() else { return nil }
                strings.append(string)
            }
            return strings
        }

        /// A table up to its end marker (type 8).
        mutating func table(strings: [String]?) -> [String: Value]? {
            var table: [String: Value] = [:]
            while let type = u8() {
                if type == 8 { return table }
                guard let key = key(strings: strings), let value = value(of: type, strings: strings) else { return nil }
                table[key] = value
            }
            return nil
        }

        private mutating func key(strings: [String]?) -> String? {
            guard let strings else { return cString() }
            guard let index = u32(), Int(index) < strings.count else { return nil }
            return strings[Int(index)]
        }

        /// One value of `type`: 0 table, 1 string, 2 int32, 3 float, 7 uint64,
        /// 10 int64. A float, which nothing here reads, is kept as its bits.
        private mutating func value(of type: UInt8, strings: [String]?) -> Value? {
            switch type {
            case 0: table(strings: strings).map(Value.table)
            case 1: cString().map(Value.string)
            case 2: u32().map { .number(Int64(Int32(bitPattern: $0))) }
            case 3: u32().map { .number(Int64($0)) }
            case 7, 10: i64().map(Value.number)
            default: nil
            }
        }
    }
}

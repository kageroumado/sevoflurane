import Foundation
import Observation

/// Newer engine and renderer components the release feed has, shown as a dot
/// on the popover's gear; the app's own updater has the footer's version chip.
@MainActor
@Observable
final class UpdateSummary {
    static let shared = UpdateSummary()

    /// What is waiting, already worded: `Dormison r12`, `DXMT 0.81`.
    private(set) var waiting: [String] = []

    /// One line for the gear, or `nil` when there is nothing to say.
    var summary: String? {
        waiting.isEmpty ? nil : String(localized: "Newer in Settings: \(ListFormatter.localizedString(byJoining: waiting))")
    }

    private var hasChecked = false

    /// One check, the first time the popover opens.
    func checkOnce() {
        guard !hasChecked else { return }
        hasChecked = true
        Task(name: "Check what the release feed has") { [weak self] in
            guard let manifest = try? await EngineManifest.fetch() else { return }
            let engine = Engine.active.root
            let engines = SetupProbe.managedEngineVersions()
            guard let self else { return }
            waiting = [Self.newerEngine(in: manifest, installed: engines)].compactMap(\.self)
                + Self.newerComponents(in: manifest, engine: engine)
        }
    }

    /// The feed's engine, as the picker names it, when every managed engine
    /// here is older; nil with none, where the picker offers one.
    static func newerEngine(
        in manifest: EngineManifest, installed: [String],
    ) -> String? {
        guard let release = try? manifest.release(), !installed.isEmpty,
              isNewerEngine(release.version, thanAll: installed)
        else { return nil }
        return Engine.managedDisplayName(release.version)
    }

    /// Every renderer component the feed names a version of that beats the
    /// one the engine ships and everything added here.
    static func newerComponents(in manifest: EngineManifest, engine: URL) -> [String] {
        RendererVersions.Component.allCases.compactMap { component in
            let have = RendererVersions.installed(component).map(\.version)
                + [RendererVersions.defaultVersion(component, engine: engine)].compactMap(\.self)
            let tested = (manifest.components?[component.rawValue] ?? []).map(\.version)
            return newerVersion(tested: tested, have: have).map { "\(component.label) \($0)" }
        }
    }

    /// The feed's newest version of a component when everything here is
    /// older; nil with nothing to compare against.
    static func newerVersion(tested: [String], have: [String]) -> String? {
        guard !have.isEmpty, let newest = newest(of: tested), isNewer(newest, thanAll: have)
        else { return nil }
        return newest
    }

    /// Version strings compare the way a person reads them: `0.9` before
    /// `0.10`, and `1.10.3-20230507-repack` as one run of numbers.
    static func isNewer(_ version: String, thanAll others: [String]) -> Bool {
        others.allSatisfy { $0.localizedStandardCompare(version) == .orderedAscending }
    }

    /// An engine name compares in publishing order
    /// (``Engine/isOlderVersion(_:than:)``), where a beta precedes the release
    /// of its number.
    static func isNewerEngine(_ version: String, thanAll installed: [String]) -> Bool {
        installed.allSatisfy { Engine.isOlderVersion($0, than: version) }
    }

    static func newest(of versions: [String]) -> String? {
        versions.max { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

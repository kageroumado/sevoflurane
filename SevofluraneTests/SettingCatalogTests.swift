import Foundation
import SwiftUI
import Testing
@testable import Sevoflurane

/// The chain from a control to the engine, one link at a time: a setting in
/// the catalog that a control can change and nothing downstream reads is the
/// failure this suite exists to catch.
@MainActor
struct SettingCatalogTests {
    /// A value other than the one an empty level has, for any setting.
    private func sample(for setting: Setting) -> SettingValue {
        switch setting.control {
        case .toggle: .flag(true)
        case let .choices(choices), let .tuning(choices): .choice(choices.last!.value)
        case .upscaler: .choice("anime4k-c")
        }
    }

    @Test
    func `every setting is in the catalog once, and every group has rows at both levels`() {
        #expect(Set(SettingCatalog.all.map(\.id)) == Set(SettingID.allCases))
        #expect(SettingCatalog.all.count == SettingID.allCases.count)
        for group in SettingGroup.allCases {
            #expect(!SettingCatalog.settings(in: group, at: .bottle).isEmpty)
            #expect(!SettingCatalog.settings(in: group, at: .game).isEmpty)
        }
    }

    @Test
    func `a value written is the value read, and nil hands the key back`() {
        for setting in SettingCatalog.all {
            var values = ConfigValues.empty
            let value = sample(for: setting)
            setting.write(&values, value)
            #expect(setting.read(values) == value, "\(setting.id)")
            #expect(values.hasSettings, "\(setting.id) is no setting to the store")
            setting.write(&values, nil)
            #expect(setting.read(values) == nil, "\(setting.id)")
        }
    }

    @Test
    func `every game-level setting reaches what the engine reads`() {
        for setting in SettingCatalog.all where setting.levels.contains(.game) {
            var values = ConfigValues.empty
            values.exes = ["game.exe"]
            let before = ConfigMaterializer.gameLines(1, values) + ConfigRegistry.gameEntries(values).map(\.place)
            setting.write(&values, sample(for: setting))
            let lines = ConfigMaterializer.gameLines(1, values)
            let entries = ConfigRegistry.gameEntries(values)
            let value = setting.read(values)
            switch setting.carrier {
            case .rendererPayload:
                // Either the env file carries it, or the row says the client will.
                #expect(
                    lines != ConfigMaterializer.gameLines(1, .empty) || setting.reach(value) == .clientRestart,
                    "\(setting.id) reaches a game by neither route",
                )
                continue
            default:
                #expect(lines + entries.map(\.place) != before, "\(setting.id) changes nothing a game reads")
            }
            switch setting.carrier {
            case let .environment(keys):
                for key in keys {
                    #expect(lines.contains { $0.hasPrefix("\(key)=") }, "\(setting.id) writes no \(key)")
                }
            case let .registry(name):
                #expect(entries.contains { $0.name == name }, "\(setting.id) writes no \(name)")
            case .rendererPayload:
                break
            }
        }
    }

    @Test
    func `every bottle-level setting has its carrier in what the bottle writes`() {
        let lines = ConfigMaterializer.bottleLines(SteamBottle.name)
        let entries = ConfigRegistry.desired(bottle: SteamBottle.name)
        for setting in SettingCatalog.all where setting.levels.contains(.bottle) {
            switch setting.carrier {
            case let .environment(keys):
                // The bottle writes the mouse line only for Linear and the
                // processor line only for a cap: an absent line is the system
                // curve and every processor, which are the defaults.
                for key in keys where !["SEVO_LINEAR_MOUSE", "SEVO_CPU_COUNT"].contains(key) {
                    #expect(lines.contains { $0.hasPrefix("\(key)=") }, "\(setting.id) writes no \(key)")
                }
            case let .registry(name):
                #expect(entries.contains { $0.name == name }, "\(setting.id) writes no \(name)")
            case .rendererPayload:
                break
            }
        }
    }

    @Test
    func `the Renderer row and Settings › Graphics open the same words`() {
        let help = SettingCatalog.setting(.renderer).copy.help
        #expect(help?.entries.map(\.text) == Renderer.allCases.filter { $0 != .auto }.map(\.guidance))
    }
}

/// The one write path, against a copy of the store in memory.
@MainActor
struct SettingsStoreTests {
    private func store(_ scope: SettingScope) -> (SettingsStore, InMemorySettingsEnvironment) {
        let environment = InMemorySettingsEnvironment(seed: [
            .bottle("Test"): .empty, .game(7, bottle: "Test"): .empty,
        ])
        return (SettingsStore(scope: scope, environment: environment), environment)
    }

    @Test
    func `sending a value stores it, shows it, and reaches the environment once`() {
        let (store, environment) = store(.game(7, bottle: "Test"))
        let fps = SettingCatalog.setting(.fps)
        store.send(.set(.fps, .flag(true)))
        #expect(store.own(fps) == .flag(true))
        #expect(environment.values(.game(7, bottle: "Test")).fps == true)
        store.send(.set(.fps, .flag(true)))
        #expect(environment.updates.count == 1)
        store.send(.set(.fps, nil))
        #expect(store.own(fps) == nil)
    }

    @Test
    func `a game inherits what the bottle sets, until it sets its own`() {
        let environment = InMemorySettingsEnvironment(seed: [
            .bottle("Test"): .empty, .game(7, bottle: "Test"): .empty,
        ])
        let bottle = SettingsStore(scope: .bottle("Test"), environment: environment)
        let game = SettingsStore(scope: .game(7, bottle: "Test"), environment: environment)
        let mouse = SettingCatalog.setting(.mouse)
        bottle.send(.set(.mouse, .choice(MouseCurve.linear.rawValue)))
        #expect(game.inherited(mouse) == .choice("linear"))
        #expect(game.effective(mouse) == .choice("linear"))
        game.send(.set(.mouse, .choice(MouseCurve.system.rawValue)))
        #expect(game.effective(mouse) == .choice("system"))
    }

    @Test
    func `every binding writes through: a control that changes nothing fails here`() throws {
        let (store, environment) = store(.bottle("Test"))
        for setting in SettingCatalog.settings(in: .picture, at: .bottle)
            + SettingCatalog.settings(in: .mouse, at: .bottle)
            + SettingCatalog.settings(in: .performance, at: .bottle) {
            let before = environment.values(.bottle("Test"))
            switch setting.control {
            case .toggle:
                let binding = store.flagBinding(setting)
                binding.wrappedValue.toggle()
            case let .choices(choices), let .tuning(choices):
                let binding = store.choiceBinding(setting)
                binding.wrappedValue = try #require(choices.first { $0.value != binding.wrappedValue }?.value)
            case .upscaler:
                store.binding(setting).wrappedValue = .choice("anime4k-c")
            }
            #expect(environment.values(.bottle("Test")) != before, "\(setting.id)")
        }
    }

    @Test
    func `the custom preset brings its parameters and takes them away`() {
        var values = ConfigValues.empty
        SettingReducer.reduce(&values, .set(.tuning, .choice("custom")))
        #expect(values.tuningParameters == .experimental)
        let own = TuningParameters(waitSpin: 100, adaptive: false, objectSpin: 0)
        SettingReducer.reduce(&values, .setTuningParameters(own))
        #expect(values.tuningParameters == own)
        SettingReducer.reduce(&values, .set(.tuning, .choice("standard")))
        #expect(values.tuningParameters == nil)
        SettingReducer.reduce(&values, .setTuningParameters(own))
        #expect(values.tuningParameters == nil)
    }

    @Test
    func `a library's load order is set, changed and taken away`() {
        var values = ConfigValues.empty
        SettingReducer.reduce(&values, .setDLLOverride(library: "dinput8", order: "n,b"))
        #expect(values.dllOverrides == ["dinput8": "n,b"])
        SettingReducer.reduce(&values, .setDLLOverride(library: "dinput8", order: nil))
        #expect(values.dllOverrides == nil)
    }
}

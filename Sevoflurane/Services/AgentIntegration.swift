import AppKit
import Foundation

/// Puts the bundled `sevo` on PATH and registers its MCP server with the AI
/// agents on this machine, on explicit opt-in (the wizard or Settings ›
/// General). Each agent is its own switch, and nothing is written for one
/// that isn't installed.
@MainActor
enum AgentIntegration {
    nonisolated static let symlinkPath = "/usr/local/bin/\(AppIdentity.commandName)"

    /// What a user pastes into any other agent's MCP configuration.
    nonisolated static let manualCommand = "\(symlinkPath) mcp"

    /// The name the server registers under everywhere.
    nonisolated static let serverName = AppIdentity.commandName

    static var bundledCLI: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sevo")
    }

    /// Whether the symlink resolves to a binary that still exists.
    static var isCLIInstalled: Bool {
        guard let destination = try? FileManager.default
            .destinationOfSymbolicLink(atPath: symlinkPath) else { return false }
        return FileManager.default.fileExists(atPath: destination)
    }

    // MARK: - The CLI symlink

    /// Symlinks the CLI into the root-owned `/usr/local/bin`, asking for an
    /// administrator password once; the link targets the bundle path, so app
    /// updates never ask again. Answers a failure description, or `nil`.
    static func installCLI() async -> String? {
        let cli = bundledCLI.path
        guard FileManager.default.fileExists(atPath: cli) else {
            return "the bundled sevo binary is missing"
        }
        guard mayReplace(at: symlinkPath) else {
            EventLog.enqueue(.app, "\(symlinkPath) is not a link to this app's sevo, so the CLI install leaves it")
            return String(localized: "\(symlinkPath) belongs to another program, so Sevoflurane leaves it in place.")
        }
        // -h: replace a link at that path, never follow one into whatever
        // directory it points at. This runs as root.
        let command = "mkdir -p /usr/local/bin && ln -sfh \(shellQuoted(cli)) \(symlinkPath)"
        if let failure = await runPrivileged(command) {
            return failure
        }
        EventLog.enqueue(.app, "sevo CLI installed at \(symlinkPath)")
        return nil
    }

    /// The wizard's one-checkbox path: the symlink, then every agent found.
    static func install() async -> String? {
        if let failure = await installCLI() {
            return failure
        }
        for harness in Harness.allCases where isDetected(harness) {
            _ = await register(harness)
        }
        return nil
    }

    /// Unregisters every agent and removes the symlink when it points into an
    /// app bundle's `Contents/Helpers/sevo`. The uninstall passes
    /// `allowAdminPrompt: false` and leaves a root-owned link in place.
    static func remove(allowAdminPrompt: Bool = true) async {
        for harness in Harness.allCases {
            guard await isRegistered(harness) else { continue }
            _ = await unregister(harness)
        }
        let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: symlinkPath)
        guard destination != nil || FileManager.default.fileExists(atPath: symlinkPath) else { return }
        guard isOurLink(destination: destination) else {
            EventLog.enqueue(.app, "\(symlinkPath) is not a link to this app's sevo, so it stays")
            return
        }
        if (try? FileManager.default.removeItem(atPath: symlinkPath)) != nil {
            EventLog.enqueue(.app, "sevo CLI symlink removed")
            return
        }
        guard allowAdminPrompt else {
            EventLog.enqueue(.app, "sevo CLI symlink left at \(symlinkPath) (needs admin to remove)")
            return
        }
        if await runPrivileged("rm -f \(symlinkPath)") == nil {
            EventLog.enqueue(.app, "sevo CLI symlink removed")
        }
    }

    /// Whether a link at ``symlinkPath`` pointing at `destination` points into
    /// some copy of the app. `nil` is a file that is no link.
    nonisolated static func isOurLink(destination: String?) -> Bool {
        destination?.hasSuffix(".app/Contents/Helpers/sevo") ?? false
    }

    /// Whether the install may write its link at `path`: nothing is there, or
    /// a link into a copy of this app is. A user's own file or link stays.
    nonisolated static func mayReplace(at path: String) -> Bool {
        let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
        guard destination != nil || FileManager.default.fileExists(atPath: path) else { return true }
        return isOurLink(destination: destination)
    }

    // MARK: - Harnesses

    /// The agents Sevoflurane can register its MCP server with.
    enum Harness: String, CaseIterable, Identifiable {
        case claudeCode
        case claudeDesktop
        case codex
        case hermes

        nonisolated var id: String { rawValue }

        var displayName: String {
            switch self {
            case .claudeCode: "Claude Code"
            case .claudeDesktop: "Claude Desktop"
            case .codex: "Codex"
            case .hermes: "Hermes"
            }
        }

        /// Where the switch writes — the fine print under each row.
        var configDescription: String {
            switch self {
            case .claudeCode: "registered with the claude CLI (user scope), with a skill in ~/.claude/skills/sevoflurane"
            case .claudeDesktop: "~/Library/Application Support/Claude/claude_desktop_config.json"
            case .codex: "~/.codex/config.toml, via the codex CLI"
            case .hermes: "~/.hermes/config.yaml"
            }
        }
    }

    static func isDetected(_ harness: Harness) -> Bool {
        switch harness {
        case .claudeCode:
            claudeBinary != nil
        case .claudeDesktop:
            FileManager.default.fileExists(atPath: claudeDesktopDirectory.path)
        case .codex:
            codexBinary != nil
        case .hermes:
            FileManager.default.fileExists(atPath: hermesDirectory.path)
        }
    }

    static var detectedHarnesses: [Harness] {
        Harness.allCases.filter(isDetected)
    }

    /// Whether the agent's config carries the sevo server, read from the
    /// config itself. Off the main actor: `~/.claude.json` runs to megabytes.
    @concurrent
    nonisolated static func isRegistered(_ harness: Harness) async -> Bool {
        switch harness {
        case .claudeCode:
            jsonServers(at: claudeCodeConfig)?[serverName] != nil
        case .claudeDesktop:
            jsonServers(at: claudeDesktopConfig)?[serverName] != nil
        case .codex:
            fileText(codexConfig).map(codexHasServer(in:)) ?? false
        case .hermes:
            fileText(hermesConfig).map(hermesHasServer(in:)) ?? false
        }
    }

    /// Registers the server with one agent. Answers a failure description
    /// for the row to show, or `nil` on success.
    static func register(_ harness: Harness) async -> String? {
        let failure: String? = switch harness {
        case .claudeCode: await registerClaudeCode()
        case .claudeDesktop: registerClaudeDesktop()
        case .codex: await registerCodex()
        case .hermes: registerHermes()
        }
        if failure == nil {
            EventLog.enqueue(.app, "sevo MCP registered with \(harness.displayName)")
        } else {
            EventLog.enqueue(
                .app, "\(harness.displayName) MCP registration failed: \(failure ?? "")",
            )
        }
        return failure
    }

    /// Removes the server from one agent's config, leaving everything else
    /// in it untouched. Answers a failure description, or `nil`.
    static func unregister(_ harness: Harness) async -> String? {
        switch harness {
        case .claudeCode:
            #if !DEBUG
                removeClaudeSkill()
            #endif
            guard let claude = claudeBinary else { return nil }
            let result = await Subprocess.run(
                claude, ["mcp", "remove", "--scope", "user", serverName],
                capture: .combined, timeout: .seconds(30),
            )
            // "not found" is the state we wanted; only a live refusal counts.
            if result.status != 0, await isRegistered(.claudeCode) {
                return String(result.output.suffix(120))
            }
            return nil
        case .claudeDesktop:
            return editJSONServers(at: claudeDesktopConfig, requireExisting: true) { servers in
                servers.removeValue(forKey: serverName)
            }
        case .codex:
            guard let codex = codexBinary else { return nil }
            let result = await Subprocess.run(
                codex, ["mcp", "remove", serverName],
                capture: .combined, timeout: .seconds(30),
            )
            if result.status != 0, await isRegistered(.codex) {
                return String(result.output.suffix(120))
            }
            return nil
        case .hermes:
            guard let text = fileText(hermesConfig) else { return nil }
            let updated = removingHermesServer(from: text)
            guard updated != text else { return nil }
            do {
                try updated.write(to: hermesConfig, atomically: true, encoding: .utf8)
                return nil
            } catch {
                return "couldn't write ~/.hermes/config.yaml: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Claude Code

    private static var claudeBinary: String? {
        let home = UserHome.path
        return [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            home + "/.local/bin/claude",
            home + "/.claude/local/claude",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// User-scope servers live in `~/.claude.json` — read for state, but
    /// written only through the claude CLI, which owns that file.
    private nonisolated static var claudeCodeConfig: URL {
        UserHome.url
            .appendingPathComponent(".claude.json")
    }

    private static func registerClaudeCode() async -> String? {
        guard let claude = claudeBinary else { return "claude not found" }
        let result = await Subprocess.run(
            claude, ["mcp", "add", "--scope", "user", serverName, symlinkPath, "mcp"],
            capture: .combined, timeout: .seconds(30),
        )
        if result.status == 0 || result.output.contains("already exists") {
            #if !DEBUG
                installClaudeSkill()
            #endif
            return nil
        }
        return String(result.output.suffix(120))
    }

    /// Where Claude Code reads the skill that teaches it `sevo`. Only the
    /// release build writes or removes it.
    nonisolated static var claudeSkillDirectory: URL {
        UserHome.url.appendingPathComponent(".claude/skills/sevoflurane")
    }

    /// Copies the bundled skill (`Resources/Agent/SKILL.md` in the source tree,
    /// `Contents/Resources/SKILL.md` in the app) over any earlier one. A
    /// failure is logged; the server works without it.
    private static func installClaudeSkill() {
        guard let source = BundledResources.url("SKILL.md") else {
            EventLog.enqueue(.app, "Claude Code skill not installed: the bundle carries no SKILL.md")
            return
        }
        let destination = claudeSkillDirectory.appendingPathComponent("SKILL.md")
        do {
            try FileManager.default.createDirectory(at: claudeSkillDirectory, withIntermediateDirectories: true)
            try Data(contentsOf: source).write(to: destination, options: .atomic)
            EventLog.enqueue(.app, "Claude Code skill installed at ~/.claude/skills/sevoflurane")
        } catch {
            EventLog.enqueue(.app, "Claude Code skill not installed: \(error.localizedDescription)")
        }
    }

    /// Moves the skill's directory to the Trash.
    private static func removeClaudeSkill() {
        let directory = claudeSkillDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
            EventLog.enqueue(.app, "Claude Code skill moved to the Trash")
        } catch {
            EventLog.enqueue(
                .app, "Claude Code skill left at ~/.claude/skills/sevoflurane: \(error.localizedDescription)",
            )
        }
    }

    // MARK: - Claude Desktop

    private nonisolated static var claudeDesktopDirectory: URL {
        UserHome.url
            .appendingPathComponent("Library/Application Support/Claude")
    }

    private nonisolated static var claudeDesktopConfig: URL {
        claudeDesktopDirectory.appendingPathComponent("claude_desktop_config.json")
    }

    private static func registerClaudeDesktop() -> String? {
        editJSONServers(at: claudeDesktopConfig, requireExisting: false) { servers in
            servers[serverName] = ["command": symlinkPath, "args": ["mcp"]]
        }
    }

    /// Merges an edit into a `{"mcpServers": {...}}` config, keeping every
    /// other key. A file that exists but doesn't parse is left alone.
    private static func editJSONServers(
        at config: URL,
        requireExisting: Bool,
        _ edit: (inout [String: Any]) -> Void,
    ) -> String? {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: config) {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                return "\(config.lastPathComponent) isn't valid JSON — not modified"
            }
            root = parsed
        } else if requireExisting {
            return nil
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        edit(&servers)
        root["mcpServers"] = servers
        do {
            let data = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys],
            )
            try data.write(to: config, options: .atomic)
            return nil
        } catch {
            return "couldn't write \(config.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private nonisolated static func jsonServers(at config: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: config),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return root["mcpServers"] as? [String: Any]
    }

    // MARK: - Codex / ChatGPT

    /// The Codex CLI and the ChatGPT app (which bundles it) share
    /// `~/.codex/config.toml`, so registration goes through `codex mcp add`.
    private static var codexBinary: String? {
        let home = UserHome.path
        return [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            home + "/.local/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private nonisolated static var codexConfig: URL {
        UserHome.url
            .appendingPathComponent(".codex/config.toml")
    }

    nonisolated static func codexHasServer(in toml: String) -> Bool {
        toml.components(separatedBy: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces) == "[mcp_servers.\(serverName)]"
        }
    }

    private static func registerCodex() async -> String? {
        guard let codex = codexBinary else { return "codex not found" }
        let result = await Subprocess.run(
            codex, ["mcp", "add", serverName, "--", symlinkPath, "mcp"],
            capture: .combined, timeout: .seconds(30),
        )
        if result.status == 0 { return nil }
        if await isRegistered(.codex) {
            return nil
        }
        return String(result.output.suffix(120))
    }

    // MARK: - Hermes

    /// Hermes (NousResearch/hermes-agent) reads `~/.hermes/config.yaml` and
    /// its CLI cannot add a stdio server, so the entry is spliced in as a
    /// marker-bounded block by line edits; a YAML round-trip would reformat
    /// the user's file.
    private nonisolated static var hermesDirectory: URL {
        UserHome.url.appendingPathComponent(".hermes")
    }

    private nonisolated static var hermesConfig: URL {
        hermesDirectory.appendingPathComponent("config.yaml")
    }

    private nonisolated static let hermesMarkerStart = "# >>> \(serverName) (managed)"
    private nonisolated static let hermesMarkerEnd = "# <<< \(serverName)"

    private static func registerHermes() -> String? {
        let existing = fileText(hermesConfig) ?? ""
        guard let updated = addingHermesServer(to: existing) else {
            return "couldn't find a safe place in ~/.hermes/config.yaml — add "
                + "\u{201C}\(manualCommand)\u{201D} under mcp_servers yourself"
        }
        guard updated != existing else { return nil }
        do {
            try updated.write(to: hermesConfig, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return "couldn't write ~/.hermes/config.yaml: \(error.localizedDescription)"
        }
    }

    nonisolated static func hermesHasServer(in yaml: String) -> Bool {
        let active = yaml.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        }
        return active.contains { $0.trimmingCharacters(in: .whitespaces) == "\(serverName):" }
            && active.contains { $0.contains(symlinkPath) }
    }

    /// Our `mcp_servers` entry at the given child indent, markers included.
    private nonisolated static func hermesBlock(indent: String) -> String {
        """
        \(indent)\(hermesMarkerStart)
        \(indent)\(serverName):
        \(indent)  command: "\(symlinkPath)"
        \(indent)  args: ["mcp"]
        \(indent)\(hermesMarkerEnd)
        """
    }

    /// The config with our server spliced in, or `nil` when there is no safe
    /// place to put it.
    nonisolated static func addingHermesServer(to text: String) -> String? {
        if hermesHasServer(in: text) { return text }
        // A stale block is taken out first, then reinstalled fresh.
        let cleaned = text.contains(hermesMarkerStart)
            ? removingHermesServer(from: text) : text
        var lines = cleaned.components(separatedBy: "\n")

        if let empty = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "mcp_servers: {}" && !$0.hasPrefix(" ")
        }) {
            // Top level only: an indented `mcp_servers: {}` belongs to something else.
            lines[empty] = "mcp_servers:\n" + hermesBlock(indent: "  ")
            return lines.joined(separator: "\n")
        }
        if let key = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "mcp_servers:" && !$0.hasPrefix(" ")
        }) {
            // A populated map: our block takes its children's indent.
            let child = lines[(key + 1)...].first {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.hasPrefix("#")
            }
            guard let child, child.hasPrefix(" ") else { return nil }
            let indent = String(child.prefix { $0 == " " })
            lines.insert(hermesBlock(indent: indent), at: key + 1)
            return lines.joined(separator: "\n")
        }
        let body = cleaned.isEmpty || cleaned == "\n" ? "" : cleaned.hasSuffix("\n") ? cleaned : cleaned + "\n"
        return body + "mcp_servers:\n" + hermesBlock(indent: "  ") + "\n"
    }

    /// Removes our managed block. Without the end marker, only lines
    /// recognizably ours go, up to the first foreign line. A childless
    /// `mcp_servers:` becomes `mcp_servers: {}` so the file stays valid YAML.
    nonisolated static func removingHermesServer(from text: String) -> String {
        var kept: [String] = []
        var inBlock = false
        for line in text.components(separatedBy: "\n") {
            if line.contains(hermesMarkerStart) { inBlock = true; continue }
            if line.contains(hermesMarkerEnd) { inBlock = false; continue }
            if inBlock {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let isOurs = trimmed == "\(serverName):"
                    || trimmed.hasPrefix("command:") && trimmed.contains(symlinkPath)
                    || trimmed == "args: [\"mcp\"]"
                    || trimmed.isEmpty
                if isOurs { continue }
                inBlock = false
            }
            kept.append(line)
        }
        for index in kept.indices where kept[index] == "mcp_servers:" {
            let next = index + 1 < kept.count ? kept[index + 1] : ""
            if next.isEmpty || !next.hasPrefix(" ") { kept[index] = "mcp_servers: {}" }
        }
        return kept.joined(separator: "\n")
    }

    // MARK: - Shared plumbing

    private nonisolated static func fileText(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    /// Runs `command` through `do shell script … with administrator
    /// privileges`. Answers a failure description ("canceled" included), or `nil`.
    private static func runPrivileged(_ command: String) async -> String? {
        let script = "do shell script \"\(appleScriptEscaped(command))\" "
            + "with administrator privileges"
        let result = await Subprocess.run(
            "/usr/bin/osascript", ["-e", script],
            capture: .combined, timeout: .seconds(120),
        )
        guard result.status == 0 else {
            if result.output.contains("canceled") {
                return "canceled"
            }
            return String(result.output.suffix(200))
        }
        return nil
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptEscaped(_ command: String) -> String {
        command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

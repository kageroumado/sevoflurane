import AppKit
import Foundation

/// Puts the bundled `sevo` on PATH and registers its MCP server with the AI
/// agents present on this machine (`Docs/release-readiness.md` §D). Always
/// explicit opt-in — the wizard's Options toggle or Settings › General —
/// and nothing is written for an agent that isn't installed; agents with no
/// stable config surface get shown the command instead.
@MainActor
enum AgentIntegration {
    static let symlinkPath = "/usr/local/bin/sevo"

    /// What a user pastes into any other agent's MCP configuration.
    static let manualCommand = "\(symlinkPath) mcp"

    static var bundledCLI: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sevo")
    }

    /// Installed means the symlink resolves to a binary that still exists —
    /// a link left behind by a moved app counts as broken, not installed.
    static var isCLIInstalled: Bool {
        guard let destination = try? FileManager.default
            .destinationOfSymbolicLink(atPath: symlinkPath) else { return false }
        return FileManager.default.fileExists(atPath: destination)
    }

    /// Symlinks the CLI into `/usr/local/bin` (root-owned on a stock
    /// machine, so this asks for an administrator password once) and
    /// registers the MCP server with every agent found. Answers a failure
    /// description, or `nil` when the link landed.
    static func install() async -> String? {
        let cli = bundledCLI.path
        guard FileManager.default.fileExists(atPath: cli) else {
            return "the bundled sevo binary is missing"
        }
        let command = "mkdir -p /usr/local/bin && ln -sf \(shellQuoted(cli)) \(symlinkPath)"
        if let failure = await runPrivileged(command) {
            return failure
        }
        EventLog.enqueue(.app, "sevo CLI installed at \(symlinkPath)")
        await registerAgents()
        return nil
    }

    /// Unregisters the agents and takes the symlink away. The uninstall
    /// flow passes `allowAdminPrompt: false` — a second password dialog
    /// mid-uninstall is worse than reporting a leftover link.
    static func remove(allowAdminPrompt: Bool = true) async {
        await unregisterAgents()
        guard FileManager.default.fileExists(atPath: symlinkPath)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: symlinkPath)) != nil
        else { return }
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

    // MARK: - Agents

    private static func registerAgents() async {
        await registerClaudeCode()
        registerClaudeDesktop()
    }

    private static func unregisterAgents() async {
        if let claude = claudeBinary {
            _ = await Subprocess.run(
                claude, ["mcp", "remove", "--scope", "user", "sevo"],
                capture: .combined, timeout: .seconds(30),
            )
        }
        editClaudeDesktopConfig { servers in
            servers.removeValue(forKey: "sevo")
        }
    }

    private static var claudeBinary: String? {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            home + "/.local/bin/claude",
            home + "/.claude/local/claude",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func registerClaudeCode() async {
        guard let claude = claudeBinary else { return }
        let result = await Subprocess.run(
            claude, ["mcp", "add", "--scope", "user", "sevo", symlinkPath, "mcp"],
            capture: .combined, timeout: .seconds(30),
        )
        if result.status == 0 || result.output.contains("already exists") {
            EventLog.enqueue(.app, "sevo MCP registered with Claude Code")
        } else {
            EventLog.enqueue(.app, "Claude Code MCP registration failed: \(result.output.suffix(120))")
        }
    }

    /// Merges the server into Claude Desktop's config, preserving every key
    /// that isn't ours. Only when the app's directory already exists.
    private static func registerClaudeDesktop() {
        let wrote = editClaudeDesktopConfig { servers in
            servers["sevo"] = ["command": symlinkPath, "args": ["mcp"]]
        }
        if wrote {
            EventLog.enqueue(.app, "sevo MCP registered with Claude Desktop")
        }
    }

    @discardableResult
    private static func editClaudeDesktopConfig(
        _ edit: (inout [String: Any]) -> Void,
    ) -> Bool {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude")
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        let config = directory.appendingPathComponent("claude_desktop_config.json")
        var root = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: config))) as? [String: Any] ?? [:]
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        edit(&servers)
        root["mcpServers"] = servers
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return false }
        return (try? data.write(to: config)) != nil
    }

    // MARK: - Privileged execution

    /// `do shell script … with administrator privileges` — the standard
    /// "install command line tool" authorization dialog. Answers a failure
    /// description ("canceled" included), or `nil` on success.
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

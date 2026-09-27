import Foundation
import Testing
@testable import Sevoflurane

/// The pure text surgery behind the per-assistant MCP switches — the parts
/// that edit files Sevoflurane doesn't own, where a wrong line eats someone's
/// config.
struct AgentIntegrationTests {
    // MARK: - The CLI link

    @Test
    func `removal leaves a sevo that is not the app's own`() {
        #expect(!AgentIntegration.isOurLink(destination: "/opt/homebrew/Cellar/sevo/1.0/bin/sevo"))
        // A plain file at the path is no link at all.
        #expect(!AgentIntegration.isOurLink(destination: nil))
        #expect(AgentIntegration.isOurLink(destination: "/Applications/Sevoflurane.app/Contents/Helpers/sevo"))
    }

    // MARK: - Hermes YAML

    @Test
    func `empty config gains a full mcp_servers block`() throws {
        let updated = try #require(AgentIntegration.addingHermesServer(to: ""))
        #expect(updated.contains("mcp_servers:"))
        #expect(updated.contains("  \(AgentIntegration.serverName):"))
        #expect(updated.contains("    command: \"\(AgentIntegration.symlinkPath)\""))
        #expect(updated.contains("    args: [\"mcp\"]"))
        #expect(AgentIntegration.hermesHasServer(in: updated))
    }

    @Test
    func `empty map placeholder is replaced, nested one is not`() throws {
        let config = """
        model: hermes-4
        mcp_servers: {}
        """
        let updated = try #require(AgentIntegration.addingHermesServer(to: config))
        #expect(updated.contains("model: hermes-4"))
        #expect(!updated.contains("mcp_servers: {}"))
        #expect(AgentIntegration.hermesHasServer(in: updated))

        let nested = """
        tool_config:
          mcp_servers: {}
        """
        let nestedUpdated = try #require(AgentIntegration.addingHermesServer(to: nested))
        // The nested map belongs to something else; ours is appended at top level.
        #expect(nestedUpdated.contains("  mcp_servers: {}"))
        #expect(nestedUpdated.contains("\nmcp_servers:\n"))
    }

    @Test
    func `populated map keeps existing servers and matches their indent`() throws {
        let config = """
        mcp_servers:
            filesystem:
                command: "npx"
                args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
        """
        let updated = try #require(AgentIntegration.addingHermesServer(to: config))
        #expect(updated.contains("filesystem:"))
        #expect(updated.contains("    \(AgentIntegration.serverName):"))
        #expect(updated.contains("      command: \"\(AgentIntegration.symlinkPath)\""))
        #expect(AgentIntegration.hermesHasServer(in: updated))
    }

    @Test
    func `adding is idempotent and removal round-trips`() throws {
        let config = """
        model: hermes-4
        mcp_servers:
          filesystem:
            command: "npx"
        """
        let once = try #require(AgentIntegration.addingHermesServer(to: config))
        #expect(AgentIntegration.addingHermesServer(to: once) == once)
        let removed = AgentIntegration.removingHermesServer(from: once)
        #expect(removed == config)
    }

    @Test
    func `removal restores the empty map and survives a damaged block`() throws {
        let alone = try #require(AgentIntegration.addingHermesServer(to: "mcp_servers: {}"))
        #expect(AgentIntegration.removingHermesServer(from: alone) == "mcp_servers: {}")

        // End marker deleted by hand: only recognizably-ours lines go, and
        // the user's next entry survives.
        let damaged = """
        mcp_servers:
          # >>> \(AgentIntegration.serverName) (managed)
          \(AgentIntegration.serverName):
            command: "\(AgentIntegration.symlinkPath)"
            args: ["mcp"]
          theirs:
            command: "their-tool"
        """
        let cleaned = AgentIntegration.removingHermesServer(from: damaged)
        #expect(!cleaned.contains("\(AgentIntegration.serverName):"))
        #expect(cleaned.contains("theirs:"))
        #expect(cleaned.contains("their-tool"))
    }

    @Test
    func `hand-added server counts as registered`() {
        let config = """
        mcp_servers:
          \(AgentIntegration.serverName):
            command: "\(AgentIntegration.symlinkPath)"
            args: ["mcp"]
        """
        #expect(AgentIntegration.hermesHasServer(in: config))
        // Commented-out lines don't.
        let commented = """
        mcp_servers: {}
        # \(AgentIntegration.serverName):
        #   command: "\(AgentIntegration.symlinkPath)"
        """
        #expect(!AgentIntegration.hermesHasServer(in: commented))
    }

    // MARK: - Codex TOML

    @Test
    func `codex table header is matched exactly`() {
        #expect(AgentIntegration.codexHasServer(in: "[mcp_servers.\(AgentIntegration.serverName)]\ncommand = \"x\""))
        #expect(AgentIntegration.codexHasServer(in: "  [mcp_servers.\(AgentIntegration.serverName)]"))
        #expect(!AgentIntegration.codexHasServer(in: "[mcp_servers.sevoflurane]"))
        #expect(!AgentIntegration.codexHasServer(in: "[mcp_servers.other]\n# [mcp_servers.\(AgentIntegration.serverName)] gone"))
    }
}

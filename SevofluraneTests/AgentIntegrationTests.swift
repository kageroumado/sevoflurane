import Foundation
import Testing
@testable import Sevoflurane

/// The pure text surgery behind the per-assistant MCP switches — the parts
/// that edit files Sevoflurane doesn't own, where a wrong line eats someone's
/// config.
struct AgentIntegrationTests {
    // MARK: - Hermes YAML

    @Test
    func `empty config gains a full mcp_servers block`() throws {
        let updated = try #require(AgentIntegration.addingHermesServer(to: ""))
        #expect(updated.contains("mcp_servers:"))
        #expect(updated.contains("  sevo:"))
        #expect(updated.contains("    command: \"/usr/local/bin/sevo\""))
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
        #expect(updated.contains("    sevo:"))
        #expect(updated.contains("      command: \"/usr/local/bin/sevo\""))
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
    func `removal restores the empty map and survives a damaged block`() {
        let alone = AgentIntegration.addingHermesServer(to: "mcp_servers: {}")!
        #expect(AgentIntegration.removingHermesServer(from: alone) == "mcp_servers: {}")

        // End marker deleted by hand: only recognizably-ours lines go, and
        // the user's next entry survives.
        let damaged = """
        mcp_servers:
          # >>> sevo (managed)
          sevo:
            command: "/usr/local/bin/sevo"
            args: ["mcp"]
          theirs:
            command: "their-tool"
        """
        let cleaned = AgentIntegration.removingHermesServer(from: damaged)
        #expect(!cleaned.contains("sevo:"))
        #expect(cleaned.contains("theirs:"))
        #expect(cleaned.contains("their-tool"))
    }

    @Test
    func `hand-added server counts as registered`() {
        let config = """
        mcp_servers:
          sevo:
            command: "/usr/local/bin/sevo"
            args: ["mcp"]
        """
        #expect(AgentIntegration.hermesHasServer(in: config))
        // Commented-out lines don't.
        let commented = """
        mcp_servers: {}
        # sevo:
        #   command: "/usr/local/bin/sevo"
        """
        #expect(!AgentIntegration.hermesHasServer(in: commented))
    }

    // MARK: - Codex TOML

    @Test
    func `codex table header is matched exactly`() {
        #expect(AgentIntegration.codexHasServer(in: "[mcp_servers.sevo]\ncommand = \"x\""))
        #expect(AgentIntegration.codexHasServer(in: "  [mcp_servers.sevo]"))
        #expect(!AgentIntegration.codexHasServer(in: "[mcp_servers.sevoflurane]"))
        #expect(!AgentIntegration.codexHasServer(in: "[mcp_servers.other]\n# [mcp_servers.sevo] gone"))
    }
}

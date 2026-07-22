import Testing
@testable import KairosDaemon

/// Pure-logic tests for the `~/.claude/settings.json` merge used to register the
/// bundled Claude Code marketplace. Exercises the transforms without touching disk.
@Suite
struct ClaudeMarketplaceTests {
    private let path = "/Applications/Kairos.app/Contents/Resources/plugins/claude-code"

    private func source(_ settings: [String: Any]) -> [String: String]? {
        guard let markets = settings["extraKnownMarketplaces"] as? [String: Any],
              let entry = markets["kairos"] as? [String: Any],
              let src = entry["source"] as? [String: String] else { return nil }
        return src
    }

    @Test
    func registerIntoEmptyWritesDirectorySource() {
        let out = ClaudeMarketplace.withMarketplace([:], path: path)
        #expect(source(out) == ["source": "directory", "path": path])
        #expect(ClaudeMarketplace.marketplacePath(in: out) == path)
    }

    @Test
    func registerPreservesUnrelatedKeysAndMarketplaces() {
        let settings: [String: Any] = [
            "model": "opus",
            "extraKnownMarketplaces": [
                "other": ["source": ["source": "github", "repo": "acme/x"]]
            ],
        ]
        let out = ClaudeMarketplace.withMarketplace(settings, path: path)
        #expect(out["model"] as? String == "opus")
        let markets = out["extraKnownMarketplaces"] as? [String: Any]
        #expect(markets?["other"] != nil)           // sibling marketplace untouched
        #expect(ClaudeMarketplace.marketplacePath(in: out) == path)
    }

    @Test
    func registerIsIdempotent() {
        let once = ClaudeMarketplace.withMarketplace([:], path: path)
        let twice = ClaudeMarketplace.withMarketplace(once, path: path)
        let markets = twice["extraKnownMarketplaces"] as? [String: Any]
        #expect(markets?.count == 1)
        #expect(ClaudeMarketplace.marketplacePath(in: twice) == path)
    }

    @Test
    func unregisterRemovesOnlyOursAndDropsEmptyContainer() {
        let out = ClaudeMarketplace.withoutMarketplace(
            ClaudeMarketplace.withMarketplace(["model": "opus"], path: path))
        #expect(out["model"] as? String == "opus")
        #expect(out["extraKnownMarketplaces"] == nil)   // container dropped when emptied
        #expect(ClaudeMarketplace.marketplacePath(in: out) == nil)
    }

    @Test
    func unregisterKeepsSiblingMarketplaces() {
        let settings = ClaudeMarketplace.withMarketplace([
            "extraKnownMarketplaces": [
                "other": ["source": ["source": "github", "repo": "acme/x"]]
            ],
        ], path: path)
        let out = ClaudeMarketplace.withoutMarketplace(settings)
        let markets = out["extraKnownMarketplaces"] as? [String: Any]
        #expect(markets?["other"] != nil)
        #expect(markets?["kairos"] == nil)
    }

    @Test
    func marketplacePathNilWhenAbsent() {
        #expect(ClaudeMarketplace.marketplacePath(in: [:]) == nil)
        #expect(ClaudeMarketplace.marketplacePath(in: ["extraKnownMarketplaces": [String: Any]()]) == nil)
    }
}

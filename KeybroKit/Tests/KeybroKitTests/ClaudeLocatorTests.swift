import Testing
@testable import KeybroKit

struct ClaudeLocatorTests {
    func locator(executables: Set<String>, shell: String?) -> ClaudeLocator {
        ClaudeLocator(home: "/Users/x", isExecutable: { executables.contains($0) }, loginShellLookup: { shell })
    }

    @Test func prefersNativeInstallOverHomebrew() {
        let l = locator(executables: ["/opt/homebrew/bin/claude", "/Users/x/.local/bin/claude"], shell: nil)
        #expect(l.locate() == "/Users/x/.local/bin/claude")
    }

    @Test func fallsBackToLoginShell() {
        let l = locator(executables: ["/Users/x/.nvm/versions/node/v22/bin/claude"], shell: "/Users/x/.nvm/versions/node/v22/bin/claude\n")
        #expect(l.locate() == "/Users/x/.nvm/versions/node/v22/bin/claude")
    }

    @Test func rejectsShellAliasesAndMissingFiles() {
        #expect(locator(executables: [], shell: "claude: aliased to foo").locate() == nil)
        #expect(locator(executables: [], shell: "/nope/claude").locate() == nil)
        #expect(locator(executables: [], shell: nil).locate() == nil)
    }
}

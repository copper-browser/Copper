import Testing
@testable import Search

// The MCP socket refuses pages from other browsers by their Origin header
// (Fork/MCP/MCP.swift): only an exact loopback host passes, not a name that
// merely starts with one or mentions one further along.

@Test(arguments: ["http://localhost:4123", "http://127.0.0.1", "https://localhost", "http://[::1]:4123", "HTTP://LOCALHOST:9"])
func loopbackOriginsReachTheSocket(_ origin: String) {
    #expect(MCP.originAllowed(origin))
}

@Test func noOriginIsAProperClient() {
    #expect(MCP.originAllowed(nil))
}

@Test(arguments: ["http://localhost.evil.example", "http://127.0.0.1.evil.example", "https://evil.example/?x=://localhost",
                  "http://x.com/?a=://localhost", "null", "", "file://localhost", "ws://localhost", "localhost", "http://"])
func otherOriginsAreForbidden(_ origin: String) {
    #expect(!MCP.originAllowed(origin))
}

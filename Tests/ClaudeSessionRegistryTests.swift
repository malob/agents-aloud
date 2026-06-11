import Foundation
import Testing
@testable import ClaudeCodeVoice

struct ClaudeSessionRegistryTests {
    private func makeRegistryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCodeVoice-RegistryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeEntry(
        in directory: URL,
        pid: Int32,
        sessionID: String,
        entrypoint: String,
        name: String? = nil,
        status: String? = nil
    ) throws {
        var fields = [
            "\"pid\":\(pid)",
            "\"sessionId\":\"\(sessionID)\"",
            "\"cwd\":\"/tmp/project\"",
            "\"startedAt\":\(Int64(Date().timeIntervalSince1970 * 1000))",
            "\"kind\":\"interactive\"",
            "\"entrypoint\":\"\(entrypoint)\"",
        ]
        if let name { fields.append("\"name\":\"\(name)\"") }
        if let status { fields.append("\"status\":\"\(status)\"") }
        let json = "{\(fields.joined(separator: ","))}"
        // Keyed by sessionID, not pid: several fixtures share this test
        // process's pid, and the reader doesn't depend on filenames.
        try json.write(
            to: directory.appendingPathComponent("\(sessionID).json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }

    // A PID that is genuinely dead: spawn a trivial process, let it
    // exit, and use its identifier. (kill(pid, 0) then fails with
    // ESRCH; the reuse window between exit and assertion is far too
    // small for macOS's sequential PID allocation to wrap.)
    private func deadPID() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    @Test
    func missingDirectoryReturnsNilToSignalFallback() {
        let registry = ClaudeSessionRegistry(
            directory: URL(fileURLWithPath: "/var/empty/no-such-registry-\(UUID().uuidString)", isDirectory: true)
        )
        #expect(registry.loadLiveSessions() == nil)
    }

    @Test
    func emptyDirectoryMeansNothingRunning() throws {
        let directory = try makeRegistryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(ClaudeSessionRegistry(directory: directory).loadLiveSessions() == [])
    }

    @Test
    func filtersSDKEntrypointsAndDeadProcesses() throws {
        // The sdk-cli exclusion is load-bearing: this app's own speech
        // rewriter spawns `claude --print` per message, and those runs
        // register with kind "interactive"(!) — only entrypoint
        // distinguishes them. Without the filter the sidebar would
        // flash a phantom session on every rewrite.
        let directory = try makeRegistryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let alivePID = ProcessInfo.processInfo.processIdentifier
        try writeEntry(in: directory, pid: alivePID, sessionID: "terminal", entrypoint: "cli", name: "Named one", status: "busy")
        // Desktop entries carry neither name nor status.
        try writeEntry(in: directory, pid: alivePID, sessionID: "desktop", entrypoint: "claude-desktop")
        try writeEntry(in: directory, pid: alivePID, sessionID: "rewriter", entrypoint: "sdk-cli")
        try writeEntry(in: directory, pid: try deadPID(), sessionID: "crashed", entrypoint: "cli")

        let sessions = try #require(ClaudeSessionRegistry(directory: directory).loadLiveSessions())
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionID, $0) })

        #expect(Set(byID.keys) == ["terminal", "desktop"])
        #expect(byID["terminal"]?.name == "Named one")
        #expect(byID["terminal"]?.activity == .busy)
        #expect(byID["desktop"]?.name == nil)
        #expect(byID["desktop"]?.activity == nil)
    }

    @Test
    func projectDirectoryNameReplacesAllNonAlphanumerics() {
        // Verified against real ~/.claude/projects entries: dots and
        // underscores become dashes, not just slashes — /.config
        // produces the double dash.
        #expect(
            ClaudeSessionRegistry.projectDirectoryName(forCWD: "/Users/malo/.config/nix-config")
                == "-Users-malo--config-nix-config"
        )
        #expect(
            ClaudeSessionRegistry.projectDirectoryName(forCWD: "/private/var/folders/tl/abc_def/T")
                == "-private-var-folders-tl-abc-def-T"
        )
    }
}

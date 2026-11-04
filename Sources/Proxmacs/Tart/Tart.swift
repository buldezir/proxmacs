import Foundation

/// One row of `tart list --format json`.
struct TartVM: Decodable, Hashable {
    var name: String
    var state: String
    var running: Bool
    var source: String

    enum CodingKeys: String, CodingKey {
        case name = "Name", state = "State", running = "Running", source = "Source"
    }
}

enum IPResolver: String {
    case dhcp, arp, agent
}

/// Thin wrapper around the official (entitlement-signed) `tart` binary.
struct Tart {
    let path: String

    static func locate() -> Tart? {
        var candidates = ["/opt/homebrew/bin/tart", "/usr/local/bin/tart"]
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            candidates += envPath.split(separator: ":").map { "\($0)/tart" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(Tart.init)
    }

    /// Points Tart at the configured VM storage.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TART_HOME"] = Paths.tartHome.path
        return env
    }

    /// Refuses to run while VM storage is unavailable: Tart would otherwise create an empty home
    /// in its place and report every VM as gone.
    @discardableResult
    func run(_ args: [String], timeout: TimeInterval? = nil) async throws -> String {
        try Storage.require(.vms)
        return try await Shell.check(path, args, timeout: timeout, environment: Self.environment)
    }

    func version() async -> String? {
        try? await Shell.check(path, ["--version"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func list() async throws -> [TartVM] {
        let json = try await run(["list", "--format", "json", "--source", "local"])
        return try JSONDecoder().decode([TartVM].self, from: Data(json.utf8))
    }

    func ip(_ name: String, resolver: IPResolver) async -> String? {
        let out = try? await run(["ip", name, "--resolver", resolver.rawValue], timeout: 10)
        let ip = out?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ip.isEmpty ? nil : ip
    }

    func createLinux(_ name: String, diskSizeGB: Int) async throws {
        try await run(["create", name, "--linux", "--disk-size", String(diskSizeGB)])
    }

    func set(_ name: String, cpu: Int? = nil, memoryMB: Int? = nil, disk: URL? = nil, diskSizeGB: Int? = nil,
             randomMAC: Bool = false) async throws {
        var args = ["set", name]
        if randomMAC { args.append("--random-mac") }
        if let cpu { args += ["--cpu", String(cpu)] }
        if let memoryMB { args += ["--memory", String(memoryMB)] }
        if let disk { args += ["--disk", disk.path] }
        if let diskSizeGB { args += ["--disk-size", String(diskSizeGB)] }
        try await run(args)
    }

    /// Asks the guest to shut down, forcing it off after `timeout` seconds (0 = immediately).
    func stop(_ name: String, timeout: Int = 30) async throws {
        // `tart stop` kills `tart run` when the guest doesn't shut down in time (at once with timeout 0), which the
        // runner can't tell from a crash by itself: without the marker it would start a VM on login again.
        let marker = LaunchAgent.stopMarker(name)
        try? Data().write(to: marker)
        do {
            try await run(["stop", name, "--timeout", String(timeout)], timeout: TimeInterval(timeout + 15))
        } catch {
            // The VM may still be running, and its next crash is one.
            try? FileManager.default.removeItem(at: marker)
            throw error
        }
    }

    func delete(_ name: String) async throws {
        try await run(["delete", name])
    }

    /// Runs a command in the guest via tart-guest-agent.
    func exec(_ name: String, _ command: [String], timeout: TimeInterval = 30) async throws -> CommandResult {
        try Storage.require(.vms)
        return try await Shell.run(path, ["exec", name] + command, timeout: timeout, environment: Self.environment)
    }
}

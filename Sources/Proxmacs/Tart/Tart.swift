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

/// A VM's config.json, which Tart owns. nil when it can't be read (VM storage offline, VM missing).
enum TartConfig {
    static func url(_ vm: String) -> URL { Paths.tartVMDir(vm).appending(path: "config.json") }

    static func read(_ file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The six bytes of a MAC address, so 0a:… and a:…, or upper and lower case, compare equal.
    static func macBytes(_ mac: String) -> [UInt8]? {
        let bytes = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        return bytes.count == 6 && mac.split(separator: ":").count == 6 ? bytes : nil
    }
}

/// The guest OS Tart records in a VM's config.json. Only Linux guests are provisioned with cloud-init.
enum GuestOS: String, Codable, Sendable {
    case linux, darwin

    init?(config: [String: Any]) {
        guard let os = config["os"] as? String else { return nil }
        self.init(rawValue: os)
    }

    /// From Tart's config.json, or while that can't be read (VM storage offline) the OS Proxmacs last saw there
    /// (VMMeta.os). nil only for a VM whose config it has never read.
    static func of(_ vm: String) -> GuestOS? {
        read(TartConfig.url(vm)) ?? VMMeta.load(vm)?.os
    }

    static func read(_ configFile: URL) -> GuestOS? {
        TartConfig.read(configFile).flatMap(GuestOS.init(config:))
    }

    /// Asks the guest, through its agent, to reboot. A macOS guest restarts in place, but `tart exec` never returns
    /// once the guest goes down, so a background job restarts it after the call has returned. Without passwordless
    /// sudo it exits with `noSudoStatus` instead, so a reboot that couldn't happen isn't reported as one.
    static func rebootCommand(_ os: GuestOS?) -> [String] {
        guard os == .darwin else { return ["systemctl", "reboot"] }
        return ["/bin/sh", "-c",
                "/usr/bin/sudo -n /usr/bin/true || exit \(noSudoStatus); (sleep 2; /usr/bin/sudo -n /sbin/shutdown -r now) </dev/null >/dev/null 2>&1 &"]
    }

    /// `tart exec` passes the guest command's exit status through, and fails with other codes itself.
    static let noSudoStatus: Int32 = 99
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
             randomMAC: Bool = false, randomSerial: Bool = false) async throws {
        try await run(Self.setArguments(name, cpu: cpu, memoryMB: memoryMB, disk: disk, diskSizeGB: diskSizeGB,
                                        randomMAC: randomMAC, randomSerial: randomSerial))
    }

    /// `randomSerial`: a new machine identifier (`ecid` in config.json) for a macOS VM, which the guest sees as its
    /// serial number and IOPlatformUUID.
    static func setArguments(_ name: String, cpu: Int? = nil, memoryMB: Int? = nil, disk: URL? = nil, diskSizeGB: Int? = nil,
                             randomMAC: Bool = false, randomSerial: Bool = false) -> [String] {
        var args = ["set", name]
        if randomMAC { args.append("--random-mac") }
        if randomSerial { args.append("--random-serial") }
        if let cpu { args += ["--cpu", String(cpu)] }
        if let memoryMB { args += ["--memory", String(memoryMB)] }
        if let disk { args += ["--disk", disk.path] }
        if let diskSizeGB { args += ["--disk-size", String(diskSizeGB)] }
        return args
    }

    /// Asks the guest to shut down, forcing it off after `timeout` seconds (0 = immediately).
    func stop(_ name: String, timeout: Int = 30) async throws {
        try await run(["stop", name, "--timeout", String(timeout)], timeout: TimeInterval(timeout + 15))
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

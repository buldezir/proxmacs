import Foundation

/// What the guest reports about itself through tart-guest-agent.
struct GuestInfo: Sendable {
    struct Interface: Sendable {
        var name: String
        var mac: String?
        var addresses: [String]
    }

    struct Filesystem: Sendable {
        var device: String
        var type: String
        var mount: String
        var size: UInt64
        var used: UInt64
    }

    var os: String?
    var kernel: String?
    var hostname: String?
    var uptime: TimeInterval?
    var interfaces: [Interface] = []
    var filesystems: [Filesystem] = []
    var updated = Date()

    /// One agent call: section markers followed by each command's output.
    static let script = """
        echo @os; (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")
        echo @kernel; uname -r
        echo @hostname; hostname
        echo @uptime; cat /proc/uptime
        echo @ip; ip -j addr 2>/dev/null
        echo @df; df -PT -B1 -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs -x virtiofs 2>/dev/null
        """

    static func fetch(_ vm: String, tart: Tart) async throws -> GuestInfo {
        let result = try await GuestShell.shared.run(vm, script, timeout: 10, tart: tart)
        guard result.succeeded else { throw ProxmacsError("The guest's report failed (status \(result.status))") }
        return parse(result.stdout)
    }

    /// The guest's first global IPv4 address, as `tart ip --resolver agent` reports it, or nil when
    /// the agent can't be reached (yet: it's installed on first boot).
    static func address(_ vm: String, tart: Tart) async -> String? {
        let script = #"ip -4 -o addr show scope global | awk '{ split($4, a, "/"); print a[1] }'"#
        guard let result = try? await GuestShell.shared.run(vm, script, timeout: 10, tart: tart), result.succeeded else { return nil }
        return result.stdout.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func parse(_ text: String) -> GuestInfo {
        var sections: [String: [Substring]] = [:]
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@"), line.count < 12, !line.contains(" ") {
                current = String(line.dropFirst())
            } else {
                sections[current, default: []].append(line)
            }
        }
        func first(_ key: String) -> String? {
            sections[key]?.lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        }

        var info = GuestInfo(os: first("os"), kernel: first("kernel"), hostname: first("hostname"))
        info.uptime = first("uptime")?.split(separator: " ").first.flatMap { TimeInterval($0) }

        if let json = sections["ip"]?.joined(separator: "\n").data(using: .utf8),
           let list = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] {
            info.interfaces = list.compactMap { item in
                guard let name = item["ifname"] as? String, name != "lo" else { return nil }
                let addresses = (item["addr_info"] as? [[String: Any]] ?? []).compactMap { addr -> String? in
                    guard let local = addr["local"] as? String, let prefix = addr["prefixlen"] as? Int else { return nil }
                    return "\(local)/\(prefix)"
                }
                return Interface(name: name, mac: item["address"] as? String, addresses: addresses)
            }
        }

        for line in sections["df"]?.dropFirst() ?? [] {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 7, let size = UInt64(fields[2]), let used = UInt64(fields[3]), size > 0 else { continue }
            let mount = fields[6...].joined(separator: " ")
            info.filesystems.append(Filesystem(device: String(fields[0]), type: String(fields[1]), mount: mount, size: size, used: used))
        }
        return info
    }
}

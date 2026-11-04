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

    /// macOS has none of the tools above (its BSD df even rejects the GNU options, failing the whole report), so it
    /// gets its own. Called by absolute path: /sbin is outside the agent's PATH, and a Homebrew tool of the same
    /// name elsewhere on it must not stand in.
    static let macOSScript = """
        echo @os; echo "$(/usr/bin/sw_vers -productName) $(/usr/bin/sw_vers -productVersion) ($(/usr/bin/sw_vers -buildVersion))"
        echo @kernel; /usr/bin/uname -r
        echo @hostname; /bin/hostname
        echo @uptime; /usr/sbin/sysctl -n kern.boottime | /usr/bin/awk -v now="$(/bin/date +%s)" '{ gsub(",", "", $4); print now - $4 }'
        echo @ifconfig; /sbin/ifconfig
        echo @mount; /sbin/mount
        echo @dfk; /bin/df -k -P -l
        """

    static func fetch(_ vm: String, tart: Tart) async throws -> GuestInfo {
        let macOS = GuestOS.of(vm) == .darwin
        let result = try await GuestShell.shared.run(vm, macOS ? macOSScript : script, timeout: 10, tart: tart)
        guard result.succeeded else { throw ProxmacsError("The guest's report failed (status \(result.status))") }
        return macOS ? parseMacOS(result.stdout) : parse(result.stdout)
    }

    /// The guest's first global IPv4 address, as `tart ip --resolver agent` reports it, or nil when
    /// the agent can't be reached (yet: it's installed on first boot).
    static func address(_ vm: String, tart: Tart) async -> String? {
        // macOS has no `ip`, and its ifconfig is in /sbin, outside the agent's PATH.
        let macOS = GuestOS.of(vm) == .darwin
        let script = macOS ? "/sbin/ifconfig" : #"ip -4 -o addr show scope global | awk '{ split($4, a, "/"); print a[1] }'"#
        guard let result = try? await GuestShell.shared.run(vm, script, timeout: 10, tart: tart), result.succeeded else { return nil }
        if macOS { return ifconfigAddress(result.stdout, mac: TartConfig.macAddress(vm)) }
        return result.stdout.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The guest's IPv4 address in macOS `ifconfig` output: the one on Tart's network card, found by its MAC address,
    /// so a bridge, a second card or a VPN tunnel can't be taken for it. Without the MAC, or no card with it, the
    /// first address that isn't loopback or link-local.
    static func ifconfigAddress(_ text: String, mac: String? = nil) -> String? {
        if let mac = mac.flatMap(TartConfig.macBytes),
           let card = ifconfigInterfaces(text).first(where: { $0.mac.flatMap(TartConfig.macBytes) == mac }),
           let address = card.addresses.lazy.compactMap(usableIPv4).first {
            return address
        }
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0] == "inet", let address = usableIPv4(String(fields[1])) else { continue }
            return address
        }
        return nil
    }

    /// An IPv4 address, without a prefix length, that isn't loopback or link-local.
    private static func usableIPv4(_ text: String) -> String? {
        let address = text.split(separator: "/").first.map(String.init) ?? text
        guard address.contains("."), !address.contains(":"), !address.hasPrefix("127."), !address.hasPrefix("169.254.") else {
            return nil
        }
        return address
    }

    /// Whether a macOS guest answers on port 22, that is, Remote Login is on. nil when the guest can't be asked.
    static func remoteLogin(_ vm: String, tart: Tart) async -> Bool? {
        let script = "/usr/bin/nc -z -G 1 127.0.0.1 22 >/dev/null 2>&1 && echo open || echo closed"
        guard let result = try? await GuestShell.shared.run(vm, script, timeout: 5, tart: tart), result.succeeded else { return nil }
        return result.stdout.contains("open")
    }

    /// Each section marker's lines.
    private static func sections(_ text: String) -> [String: [Substring]] {
        var sections: [String: [Substring]] = [:]
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@"), line.count < 12, !line.contains(" ") {
                current = String(line.dropFirst())
            } else {
                sections[current, default: []].append(line)
            }
        }
        return sections
    }

    /// OS, kernel, host name and uptime, which both reports give the same way.
    private static func basics(_ sections: [String: [Substring]]) -> GuestInfo {
        func first(_ key: String) -> String? {
            sections[key]?.lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        }
        var info = GuestInfo(os: first("os"), kernel: first("kernel"), hostname: first("hostname"))
        info.uptime = first("uptime")?.split(separator: " ").first.flatMap { TimeInterval($0) }
        return info
    }

    static func parse(_ text: String) -> GuestInfo {
        let sections = Self.sections(text)
        var info = basics(sections)

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

    static func parseMacOS(_ text: String) -> GuestInfo {
        let sections = Self.sections(text)
        var info = basics(sections)
        info.interfaces = ifconfigInterfaces(sections["ifconfig"]?.joined(separator: "\n") ?? "")
        info.filesystems = macOSFilesystems(df: sections["dfk"] ?? [], mount: sections["mount"] ?? [])
        return info
    }

    /// The interfaces in macOS `ifconfig` output that have an IPv4 or a routable IPv6 address. macOS lists a dozen
    /// more (gif0, stf0, idle utuns) with a link-local address at most.
    static func ifconfigInterfaces(_ text: String) -> [Interface] {
        var interfaces: [Interface] = []
        var current: Interface?
        func finish() {
            if let current, current.name != "lo0", current.addresses.contains(where: { !$0.hasPrefix("fe80:") }) {
                interfaces.append(current)
            }
        }
        for line in text.split(separator: "\n") {
            if let first = line.first, !first.isWhitespace, let colon = line.firstIndex(of: ":") {
                finish()
                current = Interface(name: String(line[..<colon]), mac: nil, addresses: [])
                continue
            }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, current != nil else { continue }
            func after(_ key: String) -> Substring? {
                fields.firstIndex(of: Substring(key)).flatMap { $0 + 1 < fields.count ? fields[$0 + 1] : nil }
            }
            switch fields[0] {
            case "ether":
                current?.mac = String(fields[1])
            case "inet":
                // netmask 0xffffff00 → /24
                let prefix = after("netmask").flatMap { UInt32($0.dropFirst(2), radix: 16) }.map(\.nonzeroBitCount)
                current?.addresses.append(prefix.map { "\(fields[1])/\($0)" } ?? String(fields[1]))
            case "inet6":
                let address = fields[1].split(separator: "%").first.map(String.init) ?? String(fields[1])
                current?.addresses.append(after("prefixlen").map { "\(address)/\($0)" } ?? address)
            default:
                break
            }
        }
        finish()
        return interfaces
    }

    /// The volumes in `df -k -P` that the Finder shows too: the mount table marks the system's own (Preboot, VM, …)
    /// nobrowse. Shared folders are left out, as on Linux. APFS volumes share their container's space, so a volume's
    /// own Used leaves out its siblings ("/" holds only the system; files are on the Data volume): used here is what
    /// the container has in use.
    static func macOSFilesystems(df: [Substring], mount: [Substring]) -> [Filesystem] {
        var mounts: [String: (type: String, nobrowse: Bool)] = [:]
        for line in mount {
            // "/dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)"
            guard let on = line.range(of: " on "), let open = line.range(of: " (", options: .backwards),
                  line.hasSuffix(")"), on.upperBound <= open.lowerBound else { continue }
            let options = line[open.upperBound..<line.index(before: line.endIndex)]
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let type = options.first else { continue }
            mounts[String(line[on.upperBound..<open.lowerBound])] = (type, options.contains("nobrowse"))
        }
        return df.dropFirst().compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 6, let blocks = UInt64(fields[1]), let available = UInt64(fields[3]), blocks > 0 else { return nil }
            let mountPoint = fields[5...].joined(separator: " ")
            guard let entry = mounts[mountPoint], !entry.nobrowse, !entry.type.lowercased().contains("virtiofs") else { return nil }
            let size = blocks * 1024
            return Filesystem(device: String(fields[0]), type: entry.type, mount: mountPoint, size: size,
                              used: size - min(available * 1024, size))
        }
    }
}

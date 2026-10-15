import Foundation

struct HostInterface: Hashable, Identifiable {
    var device: String
    var name: String
    var id: String { device }
}

enum NetworkInterfaces {
    /// Physical ports from `networksetup -listallhardwareports`, excluding bridges and Thunderbolt ports.
    static func list() async -> [HostInterface] {
        guard let out = try? await Shell.check("/usr/sbin/networksetup", ["-listallhardwareports"]) else { return [] }
        var result: [HostInterface] = []
        var port: String?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("Hardware Port: ") {
                port = String(line.dropFirst("Hardware Port: ".count))
            } else if line.hasPrefix("Device: "), let name = port {
                let device = String(line.dropFirst("Device: ".count))
                if !device.hasPrefix("bridge"), !name.hasPrefix("Thunderbolt") {
                    result.append(HostInterface(device: device, name: name))
                }
                port = nil
            }
        }
        return result
    }

    /// Interface carrying the default route (the natural bridge target).
    static func defaultRoute() async -> String? {
        guard let out = try? await Shell.check("/sbin/route", ["-n", "get", "default"]) else { return nil }
        return out.split(separator: "\n")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("interface:") }
            .map { $0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces) }
    }
}

struct HostAddress: Hashable {
    var device: String
    var address: String
    var ipv6: Bool
}

extension NetworkInterfaces {
    /// Addresses of the interfaces that are up. IPv6 link-local addresses are left out: they need a zone
    /// (`%en0`) and a browser can't open them.
    static func addresses() -> [HostAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var result: [HostAddress] = []
        for entry in sequence(first: head, next: { $0?.pointee.ifa_next }) {
            guard let ifa = entry?.pointee, let sa = ifa.ifa_addr, ifa.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cBuffer: host)
            if family == AF_INET6, address.lowercased().hasPrefix("fe80:") { continue }
            result.append(HostAddress(device: String(cString: ifa.ifa_name), address: address, ipv6: family == AF_INET6))
        }
        return result
    }

    /// Addresses a server bound to `bind` accepts connections on: every address for a wildcard bind
    /// (IPv4 only for 0.0.0.0), otherwise just that address.
    static func listening(on bind: String) -> [HostAddress] {
        let all = addresses()
        switch bind {
        case "0.0.0.0", "": return all.filter { !$0.ipv6 }
        case "::": return all
        default:
            let matching = all.filter { $0.address == bind }
            return matching.isEmpty ? [HostAddress(device: "", address: bind, ipv6: bind.contains(":"))] : matching
        }
    }
}

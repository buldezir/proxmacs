import Foundation

enum OffsiteKind: String, Codable, Hashable {
    case smb, pbs
}

struct SMBSettings: Codable, Hashable {
    /// smb://user@host/share[/sub/path]
    var url: String
}

struct PBSSettings: Codable, Hashable {
    var host: String
    var port: Int = 8007
    var datastore: String
    var namespace: String?
    /// API token id, e.g. `backup@pbs!proxmacs`.
    var authId: String
    /// SHA-256 fingerprint of the server certificate (`aa:bb:…`); nil = trust the system store.
    var fingerprint: String?
}

struct OffsiteTarget: Codable, Hashable, Identifiable {
    var id = UUID().uuidString.lowercased()
    var name: String
    var kind: OffsiteKind
    var keep = 7
    var smb: SMBSettings?
    var pbs: PBSSettings?

    var location: String {
        switch kind {
        case .smb: smb?.url ?? "?"
        case .pbs:
            pbs.map { "\($0.authId) @ \($0.host):\($0.port)/\($0.datastore)\($0.namespace.map { " ns=\($0)" } ?? "")" } ?? "?"
        }
    }

    func backend() throws -> OffsiteBackend {
        let secret = Secrets.get(id)
        switch kind {
        case .smb:
            guard let smb else { throw ProxmacsError("SMB target \(name) has no URL") }
            return try ChunkStoreBackend(location: SMBLocation(parsing: smb.url), password: secret)
        case .pbs:
            guard let pbs else { throw ProxmacsError("PBS target \(name) has no settings") }
            guard let secret else { throw ProxmacsError("PBS target \(name) has no token secret") }
            return PBSBackend(settings: pbs, secret: secret)
        }
    }
}

/// Offsite targets live in offsite.json; their secrets live in secrets.json.
enum TargetStore {
    static let file = Paths.support.appending(path: "offsite.json")

    static func load() -> [OffsiteTarget] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder.proxmacs.decode([OffsiteTarget].self, from: data)) ?? []
    }

    static func save(_ targets: [OffsiteTarget]) throws {
        try JSONEncoder.proxmacs.encode(targets).write(to: file, options: .atomic)
    }

    static func target(_ idOrName: String) -> OffsiteTarget? {
        load().first { $0.id == idOrName || $0.name == idOrName }
    }

    static func add(_ target: OffsiteTarget, secret: String?) throws {
        var targets = load()
        guard !targets.contains(where: { $0.name == target.name }) else {
            throw ProxmacsError("A target named \(target.name) already exists")
        }
        targets.append(target)
        try save(targets)
        if let secret, !secret.isEmpty { try Secrets.set(target.id, secret) }
    }

    static func remove(_ id: String) throws {
        try save(load().filter { $0.id != id })
        try Secrets.set(id, nil)
    }
}

/// Secrets (SMB passwords, PBS token secrets) in a 0600 JSON file next to the config.
/// The login Keychain would prompt on every rebuild of an ad-hoc signed binary, so a file
/// with owner-only permissions (like ~/.ssh) is the pragmatic choice for this prototype.
enum Secrets {
    /// Var so tests can point at a scratch file.
    nonisolated(unsafe) static var file = Paths.support.appending(path: "secrets.json")
    private static let lock = NSLock()

    static func get(_ key: String) -> String? {
        lock.withLock { all()[key] }
    }

    /// The whole file is re-encoded on write, so the read-modify-write has to be serialized
    /// or a concurrent save (a target, a VNC credential) can lose the other's key.
    static func set(_ key: String, _ value: String?) throws {
        try lock.withLock {
            var secrets = all()
            secrets[key] = value
            let data = try JSONEncoder.proxmacs.encode(secrets)
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    private static func all() -> [String: String] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}

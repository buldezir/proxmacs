import Foundation

/// The guest macOS account that signs in to its Screen Sharing (Apple ARD auth, RFB type 30).
/// Stored in `secrets.json` next to the SMB and PBS secrets; the browser needs it to answer
/// the RFB handshake, so it is sent only to the authenticated session that asked for it.
enum VNCCredentials {
    struct Credentials: Equatable, Sendable {
        var username: String
        var password: String
    }

    static func userKey(_ vm: String) -> String { "vnc.user.\(vm)" }
    static func passKey(_ vm: String) -> String { "vnc.pass.\(vm)" }
    /// The random legacy-VNC password earlier builds of this branch stored; cleaned up with the rest.
    static func legacyKey(_ vm: String) -> String { "vnc.\(vm)" }

    static func load(_ vm: String) -> Credentials? {
        guard let username = Secrets.get(userKey(vm)), let password = Secrets.get(passKey(vm)),
              !username.isEmpty, !password.isEmpty else { return nil }
        return Credentials(username: username, password: password)
    }

    static func save(_ vm: String, username: String, password: String) throws {
        try Secrets.set(userKey(vm), username)
        try Secrets.set(passKey(vm), password)
    }

    static func clear(_ vm: String) throws {
        try Secrets.set(userKey(vm), nil)
        try Secrets.set(passKey(vm), nil)
        try Secrets.set(legacyKey(vm), nil)
    }
}

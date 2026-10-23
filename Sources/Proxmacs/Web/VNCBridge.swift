import Foundation
import HummingbirdWebSocket
import NIOCore
import NIOPosix

/// Turns Screen Sharing on inside a guest and makes sure an account can sign in, at most
/// once per VM per process.
///
/// Nothing secret goes on a command line: kickstart runs as argv through `tart exec`,
/// never through a shell, and only needs the guest to allow passwordless sudo.
actor ScreenSharingSetup {
    static let shared = ScreenSharingSetup()

    private var done: Set<String> = []
    private var inFlight: [String: Task<Void, any Error>] = [:]

    /// Makes sure a guest account can sign in at all. Non-disruptive: no agent restart, so
    /// a live session in another tab is untouched. A failure is remembered only for this
    /// call, so the next connect tries again instead of being stuck for the process's life.
    func ensure(_ vm: String) async throws {
        try await once("access:\(vm)") { try await Self.grantAccessIfMissing(vm) }
    }

    /// Turns Screen Sharing on. Restarts the agent — a live session would be dropped — so
    /// call this only when nothing is listening on :5900.
    func activate(_ vm: String) async throws {
        try await once("activate:\(vm)") {
            try await Self.run(vm, Self.activationCommand())
            try await Self.run(vm, Self.accessCommand())
            _ = try? await Self.run(vm, Self.legacyDisableCommand())
        }
    }

    /// Runs `body` at most once per `key`, coalescing concurrent callers onto one task.
    /// `key` is recorded only on success.
    private func once(_ key: String, _ body: @Sendable @escaping () async throws -> Void) async throws {
        if done.contains(key) { return }
        if let running = inFlight[key] {
            try await running.value
            return
        }
        let task = Task { try await body() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        try await task.value
        done.insert(key)
    }

    static let kickstart = "/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart"

    /// argv for enabling Screen Sharing. Testable: nothing here may carry a secret.
    static func activationCommand() -> [String] {
        ["/usr/bin/sudo", "-n", kickstart, "-activate", "-configure", "-access", "-on", "-restart", "-agent"]
    }

    /// `-access -on` only opens the service: it leaves every account at Remote Management
    /// level 0, and Screen Sharing then rejects every sign-in as "Authentication or
    /// authorization failure" no matter what password the viewer sends. Observe+control is
    /// the least that a display session needs — not file transfer, settings or shutdown.
    static func accessCommand() -> [String] {
        ["/usr/bin/sudo", "-n", kickstart, "-configure", "-allowAccessFor", "-allUsers", "-privs", "-ControlObserve"]
    }

    /// Best-effort: earlier builds of this branch turned legacy VNC auth on for every
    /// guest. Turn it back off; a failure here must not fail the activate step.
    static func legacyDisableCommand() -> [String] {
        ["/usr/bin/sudo", "-n", kickstart, "-configure", "-clientopts", "-setvnclegacy", "-vnclegacy", "no"]
    }

    /// argv for reading the guest's Remote Management policy.
    static func policyCommand() -> [String] {
        ["/usr/bin/defaults", "read", "/Library/Preferences/com.apple.RemoteManagement"]
    }

    /// argv for asking the guest whether anything accepts connections on its Screen
    /// Sharing port. Carries no secret and needs no privileges.
    static func probeCommand() -> [String] {
        ["/usr/bin/nc", "-z", "127.0.0.1", "5900"]
    }

    /// Whether the guest is not accepting connections on its Screen Sharing port. Asked
    /// of the guest itself: macOS Local Network privacy answers `EHOSTUNREACH` for a
    /// closed port just as it does for one it is blocking, so from the host the two look
    /// the same. `false` whenever we cannot tell — never restart the agent on a guess.
    static func portIsClosed(_ vm: String) async -> Bool {
        guard let tart = Tart.locate(),
              let result = try? await tart.exec(vm, probeCommand(), timeout: 20)
        else { return false }
        // nc exits 0 when something accepted and 1 when nothing did. Any other status is
        // tart failing to reach the guest at all (it uses 125), not an answer about the port.
        return result.status == 1
    }

    /// True when the guest allows every local user but has granted nobody any rights —
    /// exactly what a bare `-access -on` leaves behind. A "specified users" policy is
    /// someone's deliberate setup and must not be overwritten with all-users access.
    static func needsAccessGrant(_ policy: String) -> Bool {
        if let allUsers = setting("ARD_AllLocalUsers", in: policy), !isTrue(allUsers) {
            return false
        }
        return Int(setting("ARD_AllLocalUsersPrivs", in: policy) ?? "0") == 0
    }

    private static func isTrue(_ value: String) -> Bool {
        value == "1" || value.lowercased() == "true"
    }

    /// Reads `key = value;` out of `defaults read` output.
    private static func setting(_ key: String, in plist: String) -> String? {
        for line in plist.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, parts[0] == key else { continue }
            return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ";").union(.whitespaces))
        }
        return nil
    }

    /// Grants sign-in rights only where they are missing. Never runs anything if the
    /// guest is already configured, so a second connect costs nothing.
    private static func grantAccessIfMissing(_ vm: String) async throws {
        guard let tart = Tart.locate() else {
            throw ProxmacsError("tart is not installed. Install it with `brew install openai/tools/tart`.")
        }
        let policy = try await tart.exec(vm, policyCommand(), timeout: 20)
        guard policy.succeeded else {
            throw ProxmacsError(excerpt(policy.stderr.isEmpty ? policy.stdout : policy.stderr))
        }
        guard needsAccessGrant(policy.stdout) else { return }
        try await run(vm, accessCommand())
    }

    private static func run(_ vm: String, _ command: [String]) async throws {
        guard let tart = Tart.locate() else {
            throw ProxmacsError("tart is not installed. Install it with `brew install openai/tools/tart`.")
        }
        let result = try await tart.exec(vm, command, timeout: 20)
        guard result.succeeded else {
            throw ProxmacsError(excerpt(result.stderr.isEmpty ? result.stdout : result.stderr))
        }
    }

    private static func excerpt(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "kickstart failed" : String(trimmed.prefix(200))
    }
}

/// Why a connection to a guest's Screen Sharing port failed. The web UI turns these into
/// close reasons the user can act on.
enum GuestLinkError: Error {
    /// Nothing accepted the TCP connection — Screen Sharing is off in the guest.
    case refused
    /// macOS Local Network privacy blocked the connection entirely.
    case localNetwork
    /// Any other connect failure.
    case unreachable(String)
}

/// A live TCP connection to a guest's Screen Sharing port.
struct GuestLink: Sendable {
    /// Bytes from the guest.
    let received: AsyncStream<Data>
    let send: @Sendable ([UInt8]) async throws -> Void
    let close: @Sendable () -> Void

    static let port = 5900

    /// Connects to `<host>:<port>`. NIO first; if macOS Local Network privacy refuses a
    /// direct `connect(2)`, hop through `/usr/bin/nc` instead.
    static func connect(host: String, port: Int = GuestLink.port) async throws -> GuestLink {
        do {
            return try await nio(host: host, port: port)
        } catch {
            guard localNetworkPrivacy(error) else { throw classify(error) }
            // A spawned /usr/bin/nc inherits the user's Local Network grants where this
            // binary has none. If it cannot get through either, the user has to allow
            // Local Network for Proxmacs — nothing else can be wrong that we can see.
            return try await nc(host: host, port: port)
        }
    }

    /// Whether a connect failure is macOS Local Network privacy rather than the guest.
    /// NIO reports `IOError` directly, or one per address inside `NIOConnectionError`
    /// when happy-eyeballs tried more than one.
    static func localNetworkPrivacy(_ error: any Error) -> Bool {
        if case .localNetwork = classify(error) { return true }
        return false
    }

    static func classify(_ error: any Error) -> GuestLinkError {
        switch errno(of: error) {
        case ECONNREFUSED: return .refused
        case EHOSTUNREACH, ENETUNREACH: return .localNetwork
        default: return .unreachable(String(describing: error))
        }
    }

    private static func errno(of error: any Error) -> CInt? {
        if let io = error as? IOError {
            return preferredErrno([io.errnoCode])
        } else if let connection = error as? NIOConnectionError {
            return preferredErrno(connection.connectionErrors.compactMap { ($0.error as? IOError)?.errnoCode })
        }
        return nil
    }

    /// Happy-eyeballs tries every address, so one connect can carry several errnos.
    /// An address that refused means nothing is listening even if another was
    /// unreachable — that is the failure the user can act on. Reporting privacy
    /// instead would hide "Screen Sharing is off" and skip the auto-enable.
    static func preferredErrno(_ codes: [CInt]) -> CInt? {
        codes.first(where: { $0 == ECONNREFUSED })
            ?? codes.first(where: { $0 == EHOSTUNREACH || $0 == ENETUNREACH })
            ?? codes.first
    }

    private static func nio(host: String, port: Int) async throws -> GuestLink {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(10))
            .channelInitializer { channel in
                channel.pipeline.addHandler(GuestReader(continuation: continuation))
            }
            .connect(host: host, port: port)
            .get()
        return GuestLink(
            received: stream,
            send: { bytes in
                try await channel.writeAndFlush(ByteBuffer(bytes: bytes)).get()
            },
            close: { channel.close(promise: nil) }
        )
    }

    private static func nc(host: String, port: Int) async throws -> GuestLink {
        let hop = try NcHop(host: host, port: port)
        // nc exits at once when nothing accepts the connection. This path only runs after
        // privacy blocked the direct connect, so a hop that will not stay up is the same
        // problem, not "Screen Sharing is off".
        guard await hop.staysUp(1.5) else {
            hop.close()
            throw GuestLinkError.localNetwork
        }
        return hop.link
    }
}

/// Pushes guest bytes into the bridge's stream. Created inside a `@Sendable` channel
/// initializer, hence the conformance; the only state is a Sendable continuation.
private final class GuestReader: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    private let continuation: AsyncStream<Data>.Continuation

    init(continuation: AsyncStream<Data>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        guard buffer.readableBytes > 0 else { return }
        continuation.yield(Data(buffer.readableBytesView))
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish()
        context.close(promise: nil)
    }
}

/// A spawned `/usr/bin/nc`, kept so the bridge can write to its stdin and reap it on close.
final class NcHop: @unchecked Sendable {
    private let process: Process
    private let source: DispatchSourceRead
    private let writeFD: Int32
    private let received: AsyncStream<Data>

    init(host: String, port: Int) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = [host, String(port)]

        // nc's stdin is a socketpair, not a Pipe. These writes go through plain write(2),
        // and a write to a broken pipe raises SIGPIPE and kills the process before EPIPE
        // can be reported; SO_NOSIGPIPE (what ConsoleClient uses) only works on sockets.
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw GuestLinkError.unreachable("cannot open a channel to /usr/bin/nc (errno \(errno))")
        }
        // pair[0] is ours to write on; nc reads what we write from pair[1].
        var on: Int32 = 1
        setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let childEnd = FileHandle(fileDescriptor: pair[1], closeOnDealloc: true)
        process.standardInput = childEnd

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Darwin.close(pair[0])
            throw GuestLinkError.unreachable("cannot run /usr/bin/nc: \(error.localizedDescription)")
        }
        // The child has its own copy of the reading end. Ours has to go: while it stays
        // open, a write after nc exits would loop back to us instead of failing with EPIPE.
        try? childEnd.close()

        let writeFD = pair[0]
        let readFD = stdout.fileHandleForReading.fileDescriptor
        // Nonblocking: a write must not park a cooperative thread, and EPIPE has to come
        // back as an errno — FileHandle.write raises an ObjC exception nothing catches.
        for fd in [writeFD, readFD] {
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        let (stream, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        let source = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: .global())
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = read(readFD, &buffer, buffer.count)
                if n > 0 {
                    continuation.yield(Data(buffer[0..<n]))
                } else {
                    if n == 0 || (errno != EAGAIN && errno != EINTR) { continuation.finish() }
                    break
                }
            }
        }
        source.resume()

        self.process = process
        self.source = source
        self.writeFD = writeFD
        self.received = stream
    }

    /// The bridge handle. Built on demand so the closures can capture the hop itself.
    var link: GuestLink {
        GuestLink(
            received: received,
            send: { [self] bytes in try send(bytes) },
            close: { [self] in close() }
        )
    }

    /// True if the hop is still up after `seconds`.
    func staysUp(_ seconds: TimeInterval) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while process.isRunning {
            if ContinuousClock.now >= deadline { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    /// Writes the whole buffer, or throws once the peer is gone. POSIX `write(2)` so EPIPE
    /// arrives as an errno instead of the ObjC exception `FileHandle.write` raises.
    func send(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { write(writeFD, $0.baseAddress! + offset, bytes.count - offset) }
            if n > 0 {
                offset += n
            } else if n < 0 && (errno == EAGAIN || errno == EINTR) {
                usleep(1000)
            } else {
                throw GuestLinkError.unreachable("the Screen Sharing connection closed while sending")
            }
        }
    }

    func close() {
        source.cancel()
        if process.isRunning { process.terminate() }
    }
}

/// Bridges a guest's Screen Sharing (RFB on :5900) to a WebSocket for noVNC.
///
/// Byte-for-byte passthrough: noVNC negotiates RFB itself, including Apple ARD auth
/// (type 30) with a guest macOS account. Nothing here rewrites the handshake.
enum VNCBridge {
    /// A WebSocket close reason is capped at 123 bytes (RFC 6455). Longer ones are not
    /// truncated by the browser — they are dropped entirely, and the user gets no message.
    static let maxCloseReasonBytes = 123

    static func run(state: AppState, vm: String, inbound: WebSocketInboundStream, outbound: WebSocketOutboundWriter) async throws {
        guard VMMeta.load(vm) != nil else {
            try await close(outbound, "VM \(vm) does not exist")
            return
        }
        guard let ip = await state.ip(vm) else {
            try await close(outbound, "\(vm) has no IP yet — wait for it to finish booting, then reconnect.")
            return
        }

        // Sign-in rights first: Screen Sharing can be listening and still reject every
        // account because nothing was ever granted Remote Management access. Non-
        // disruptive, so it runs whether or not the port is open. Failure is not fatal —
        // the guest may already be set up, and the connect below is what reports trouble.
        try? await ScreenSharingSetup.shared.ensure(vm)

        let link: GuestLink
        do {
            link = try await GuestLink.connect(host: ip)
        } catch {
            // A connect that failed means we hold no session, so restarting ARD cannot
            // drop one of ours — but it can drop one another tab holds, which is exactly
            // what a listening port may mean. So turn Screen Sharing on only when nothing
            // is accepting connections, and ask the guest rather than trusting the errno:
            // privacy reports a closed port as unreachable from here.
            var off = false
            if case GuestLinkError.refused = error {
                off = true
            } else if await ScreenSharingSetup.portIsClosed(vm) {
                off = true
            }
            guard off else {
                try await close(outbound, Self.closeReason(vm, ip: ip, error: error, setup: ""))
                return
            }
            var setup = ""
            do {
                try await ScreenSharingSetup.shared.activate(vm)
                // The agent restart is not instantaneous. Give it a beat so the first
                // click connects instead of asking for a second one.
                try await Task.sleep(for: .seconds(1))
            } catch {
                setup = " Auto-setup needs the tart guest agent and passwordless sudo."
            }
            do {
                link = try await GuestLink.connect(host: ip)
            } catch {
                try await close(outbound, Self.closeReason(vm, ip: ip, error: error, setup: setup))
                return
            }
        }
        defer { link.close() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await data in link.received {
                    try await outbound.write(.binary(ByteBuffer(bytes: data)))
                }
            }
            group.addTask {
                for try await message in inbound.messages(maxSize: 1 << 20) {
                    let bytes: [UInt8] = switch message {
                    case .text(let text): Array(text.utf8)
                    case .binary(let buffer): Array(buffer.readableBytesView)
                    }
                    try await link.send(bytes)
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// Closes the WebSocket with an actionable reason, never longer than the protocol allows.
    private static func close(_ outbound: WebSocketOutboundWriter, _ reason: String) async throws {
        try await outbound.close(.unexpectedServerError, reason: cap(reason))
    }

    /// Shortens on a character boundary so a multi-byte character is never split.
    static func cap(_ text: String) -> String {
        guard text.utf8.count > maxCloseReasonBytes else { return text }
        var out = ""
        for character in text {
            let next = String(character)
            if out.utf8.count + next.utf8.count > maxCloseReasonBytes { break }
            out += next
        }
        return out
    }

    private static func closeReason(_ vm: String, ip: String, error: any Error, setup: String) -> String {
        if case GuestLinkError.localNetwork = error {
            return "Local Network blocked \(ip):5900. Allow Proxmacs in System Settings → Privacy & Security, then reconnect."
        }
        // Guidance first: if the auto-setup note overflows the cap, that is what gets cut.
        return "Cannot reach Screen Sharing in \(vm) at \(ip):5900. Enable it in System Settings → General → Sharing.\(setup)"
    }
}

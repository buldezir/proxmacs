import Foundation
import HummingbirdWebSocket
import NIOCore
import NIOPosix

/// Turns Screen Sharing on inside a macOS guest and lets its local accounts sign in. It
/// changes the guest's settings, so it runs only when someone asks from the Display tab.
///
/// Nothing secret goes on a command line: kickstart runs as argv through `tart exec`,
/// never through a shell, and only needs the guest to allow passwordless sudo.
actor ScreenSharingSetup {
    static let shared = ScreenSharingSetup()

    struct Outcome: Sendable {
        /// Whether anything in the guest changed, so that reconnecting is worth a try.
        var changed: Bool
        var message: String
    }

    private var inFlight: [String: Task<Outcome, any Error>] = [:]

    /// Turns Screen Sharing on when nothing is listening on :5900; otherwise grants local
    /// accounts observe+control where nobody has any. Not remembered: the guest can be
    /// switched off, restored or recreated, so every request looks at it afresh. Concurrent
    /// requests for one VM share a run, so a double click restarts the agent at most once.
    func setUp(_ vm: String) async throws -> Outcome {
        if let running = inFlight[vm] { return try await running.value }
        let task = Task { try await Self.setUpNow(vm) }
        inFlight[vm] = task
        defer { inFlight[vm] = nil }
        return try await task.value
    }

    private static func setUpNow(_ vm: String) async throws -> Outcome {
        // Restarting the agent drops every session, including one another tab holds, so
        // only when the guest itself says nothing is listening.
        if await portIsClosed(vm) {
            try await run(vm, activationCommand())
            try await run(vm, accessCommand())
            _ = try? await run(vm, legacyDisableCommand())
            // The agent restart is not instantaneous. Give it a beat so the reconnect that
            // follows gets through.
            try await Task.sleep(for: .seconds(1))
            return Outcome(changed: true, message: "Turned on Screen Sharing in \(vm).")
        }
        let policy = try await exec(vm, policyCommand())
        guard policy.succeeded else {
            // No Remote Management settings at all: Screen Sharing was turned on in System
            // Settings, whose own list decides who may sign in.
            if policy.stderr.contains("does not exist") {
                return Outcome(changed: false, message: "Screen Sharing in \(vm) is on. Who may sign in is set in its System Settings → General → Sharing.")
            }
            throw failure(vm, policy)
        }
        guard needsAccessGrant(policy.stdout) else {
            return Outcome(changed: false, message: "Screen Sharing in \(vm) is on and open to its local accounts. Check the user name and password.")
        }
        try await run(vm, accessCommand())
        return Outcome(changed: true, message: "Let \(vm)'s local accounts sign in to Screen Sharing.")
    }

    /// Tart records the guest OS in the VM's config.json. Setup only applies to macOS, and
    /// an unreadable config is most likely one too.
    static func isMacOS(_ vm: String) -> Bool {
        guard let data = try? Data(contentsOf: Paths.tartVMDir(vm).appending(path: "config.json")),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return true }
        return config["os"] as? String != "linux"
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

    private static func run(_ vm: String, _ command: [String]) async throws {
        let result = try await exec(vm, command)
        guard result.succeeded else { throw failure(vm, result) }
    }

    private static func exec(_ vm: String, _ command: [String]) async throws -> CommandResult {
        guard let tart = Tart.locate() else {
            throw ProxmacsError("tart is not installed. Install it with `brew install openai/tools/tart`.")
        }
        return try await tart.exec(vm, command, timeout: 20)
    }

    private static func failure(_ vm: String, _ result: CommandResult) -> ProxmacsError {
        let output = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = output.isEmpty ? "" : " (\(output.prefix(200)))"
        return ProxmacsError("Could not set up Screen Sharing in \(vm)\(detail). It needs the tart guest agent, and passwordless sudo in the guest.")
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
    /// instead would hide "Screen Sharing is off" and the offer to turn it on.
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
/// It owns both of its descriptors and closes them in `close()`: the app has about 256, and
/// every Display reconnect through this fallback opens a new hop.
final class NcHop: @unchecked Sendable {
    private let process: Process
    private let source: DispatchSourceRead
    private let writeFD: Int32
    private let received: AsyncStream<Data>
    private let lock = NSLock()
    private var closed = false

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

        // A raw pipe rather than `Pipe`, whose reading end this hop could not close itself.
        var out: [Int32] = [0, 0]
        guard pipe(&out) == 0 else {
            Darwin.close(pair[0])
            throw GuestLinkError.unreachable("cannot open a channel from /usr/bin/nc (errno \(errno))")
        }
        let childOut = FileHandle(fileDescriptor: out[1], closeOnDealloc: true)
        process.standardOutput = childOut
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Darwin.close(pair[0])
            Darwin.close(out[0])
            throw GuestLinkError.unreachable("cannot run /usr/bin/nc: \(error.localizedDescription)")
        }
        // The child has its own copies of these ends. Ours have to go: while the reading end
        // stays open, a write after nc exits would loop back to us instead of failing with
        // EPIPE, and while the writing end does, its output would never reach EOF.
        try? childEnd.close()
        try? childOut.close()

        let writeFD = pair[0]
        let readFD = out[0]
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
        // Dispatch runs this after the last event handler, so the read cannot race the close.
        source.setCancelHandler {
            Darwin.close(readFD)
            continuation.finish()
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

    /// Safe to call more than once. The bridge calls it only after its last `send` has
    /// returned, since the descriptor `send` writes to is closed here.
    func close() {
        let first = lock.withLock {
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        if process.isRunning { process.terminate() }
        source.cancel()
        Darwin.close(writeFD)
    }

    deinit { close() }
}

/// Bridges a guest's Screen Sharing (RFB on :5900) to a WebSocket for noVNC.
///
/// Byte-for-byte passthrough: noVNC negotiates RFB itself, including Apple ARD auth
/// (type 30) with a guest macOS account. Nothing here rewrites the handshake.
enum VNCBridge {
    /// A WebSocket close reason is capped at 123 bytes (RFC 6455). Longer ones are not
    /// truncated by the browser — they are dropped entirely, and the user gets no message.
    static let maxCloseReasonBytes = 123

    /// Close code for "Screen Sharing is off in this macOS guest", so the Display tab can
    /// offer to turn it on. RFC 6455 leaves 4000–4999 to applications.
    static let screenSharingOff = 4001

    static func run(state: AppState, vm: String, inbound: WebSocketInboundStream, outbound: WebSocketOutboundWriter) async throws {
        guard VMMeta.load(vm) != nil else {
            try await close(outbound, "VM \(vm) does not exist")
            return
        }
        guard await state.isRunning(vm) else {
            try await close(outbound, "\(vm) is not running. Start it, then reconnect.")
            return
        }
        guard let ip = await state.ip(vm) else {
            try await close(outbound, "\(vm) has no IP yet — wait for it to finish booting, then reconnect.")
            return
        }

        let link: GuestLink
        do {
            link = try await GuestLink.connect(host: ip)
        } catch {
            try await closeAfterFailure(outbound, vm: vm, ip: ip, error: error)
            return
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

    /// Says why the connect failed. Whether the port is closed is asked of the guest when
    /// the errno can't tell: Local Network privacy makes a closed port look unreachable.
    private static func closeAfterFailure(_ outbound: WebSocketOutboundWriter, vm: String, ip: String, error: any Error) async throws {
        let off: Bool
        if case GuestLinkError.refused = error {
            off = true
        } else {
            off = await ScreenSharingSetup.portIsClosed(vm)
        }
        if off, ScreenSharingSetup.isMacOS(vm) {
            try await close(outbound, "Screen Sharing is off in \(vm).", code: screenSharingOff)
        } else if off {
            try await close(outbound, "Nothing is listening on \(ip):5900. Start a VNC server in \(vm), then reconnect.")
        } else if case GuestLinkError.localNetwork = error {
            try await close(outbound, "Local Network blocked \(ip):5900. Allow Proxmacs in System Settings → Privacy & Security, then reconnect.")
        } else {
            try await close(outbound, "Cannot reach \(vm) at \(ip):5900. Wait for it to finish booting, then reconnect.")
        }
    }

    /// Closes the WebSocket with an actionable reason, never longer than the protocol allows.
    private static func close(_ outbound: WebSocketOutboundWriter, _ reason: String, code: Int? = nil) async throws {
        try await outbound.close(code.map { .init(codeNumber: $0) } ?? .unexpectedServerError, reason: cap(reason))
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
}

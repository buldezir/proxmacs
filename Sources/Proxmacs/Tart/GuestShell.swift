import Foundation

/// One long-lived `sh` in each guest, through a single `tart exec -i`, for the commands Proxmacs runs
/// every few seconds: the guest's address, its usage and what the VM page shows about it.
///
/// Tart (2.41.1 and earlier) never closes the guest agent connection that a `tart exec` or a
/// `tart ip --resolver agent` opens. Each one holds a file descriptor in Virtualization.framework's VM
/// process, which crashes the VM when it reaches 256 of them (openai/tart#1410), and polling did that
/// in about 15 minutes. A session holds one connection for as long as it lasts.
actor GuestShell {
    static let shared = GuestShell()

    private var sessions: [String: GuestShellSession] = [:]

    /// Runs `script` with `sh` in the guest, with stdin from /dev/null and stderr discarded. Commands
    /// for one VM run one at a time, in the order they were asked for.
    func run(_ vm: String, _ script: String, timeout: TimeInterval, tart: Tart) async throws -> CommandResult {
        let session: GuestShellSession
        if let existing = sessions[vm], existing.isAlive {
            session = existing
        } else {
            try Storage.require(.vms)
            session = try GuestShellSession(tart: tart, vm: vm)
            sessions[vm] = session
        }
        return try await session.run(script, timeout: timeout)
    }

    /// Ends the sessions of VMs that are not running any more.
    func keep(_ running: Set<String>) {
        for (vm, session) in sessions where !running.contains(vm) || !session.isAlive {
            session.end(ProxmacsError("\(vm) stopped"))
            sessions[vm] = nil
        }
    }
}

/// A `tart exec -i <vm> sh`. Each command is followed by a `printf` of a marker unique to it and the
/// command's exit status, so the output can be split per command while the shell keeps running.
final class GuestShellSession: @unchecked Sendable {
    private typealias Waiter = (marker: [UInt8], continuation: CheckedContinuation<CommandResult, Error>)

    private let process: Process
    private let writeFD: Int32
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private var waiting: [Waiter] = []
    private var failure: Error?

    init(tart: Tart, vm: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tart.path)
        process.arguments = ["exec", "-i", vm, "sh"]
        process.environment = Tart.environment

        // The shell's stdin is a socketpair, so that a write after tart exits fails with EPIPE
        // (SO_NOSIGPIPE) instead of raising SIGPIPE, which would kill Proxmacs.
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw ProxmacsError("Cannot open a channel to the guest agent (errno \(errno))")
        }
        var on: Int32 = 1
        setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let childIn = FileHandle(fileDescriptor: pair[1], closeOnDealloc: true)
        process.standardInput = childIn

        // Tart's own errors (the agent unreachable) arrive here too: the guest's stderr is discarded.
        var out: [Int32] = [0, 0]
        guard pipe(&out) == 0 else {
            Darwin.close(pair[0])
            throw ProxmacsError("Cannot open a channel from the guest agent (errno \(errno))")
        }
        let childOut = FileHandle(fileDescriptor: out[1], closeOnDealloc: true)
        process.standardOutput = childOut
        process.standardError = childOut
        do {
            try process.run()
        } catch {
            Darwin.close(pair[0])
            Darwin.close(out[0])
            throw error
        }
        // The child has its own copies of these ends. While ours stay open, the output never
        // reaches EOF when tart exits.
        try? childIn.close()
        try? childOut.close()

        let readFD = out[0]
        for fd in [pair[0], readFD] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        self.process = process
        self.writeFD = pair[0]
        self.source = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: .global())

        source.setEventHandler { [weak self] in
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = read(readFD, &chunk, chunk.count)
                if n > 0 {
                    self?.received(chunk[0..<n])
                } else {
                    if n == 0 || (errno != EAGAIN && errno != EINTR) { self?.ended() }
                    return
                }
            }
        }
        // Dispatch runs this after the last event handler, so the read cannot race the close.
        source.setCancelHandler { Darwin.close(readFD) }
        source.resume()
        process.terminationHandler = { [weak self] _ in self?.ended() }
    }

    deinit { end(ProxmacsError("The guest agent session closed")) }

    var isAlive: Bool { lock.withLock { failure == nil } }

    func run(_ script: String, timeout: TimeInterval) async throws -> CommandResult {
        let marker = "@proxmacs-\(UUID().uuidString)"
        // A subshell, so that an `exit` in the script ends only the script.
        let command = Array("(\n\(script)\n) </dev/null 2>/dev/null; printf '\\n\(marker) %d\\n' \"$?\"\n".utf8)
        let timer = Task { [weak self] in
            try await Task.sleep(for: .seconds(timeout))
            self?.end(ProxmacsError("The guest agent did not answer within \(Int(timeout)) s"))
        }
        defer { timer.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            let (queued, error): (Bool, Error?) = lock.withLock {
                if let failure { return (false, failure) }
                waiting.append((Array("\n\(marker) ".utf8), continuation))
                return (true, send(command) ? nil : ProxmacsError("The guest agent session closed"))
            }
            if !queued, let error {
                continuation.resume(throwing: error)
            } else if let error {
                end(error)  // fails every queued command, this one included
            }
        }
    }

    /// Ends the session: commands still waiting fail with `error`. Safe to call more than once.
    func end(_ error: Error) {
        let (first, abandoned): (Bool, [Waiter]) = lock.withLock {
            guard failure == nil else { return (false, []) }
            failure = error
            defer { waiting = [] }
            return (true, waiting)
        }
        guard first else { return }
        if process.isRunning { process.terminate() }
        source.cancel()
        Darwin.close(writeFD)
        for waiter in abandoned { waiter.continuation.resume(throwing: error) }
    }

    /// Called with the lock held. Nonblocking `write(2)`, so EPIPE comes back as an errno.
    private func send(_ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { write(writeFD, $0.baseAddress! + offset, bytes.count - offset) }
            if n > 0 {
                offset += n
            } else if n < 0 && (errno == EAGAIN || errno == EINTR) {
                usleep(1000)
            } else {
                return false
            }
        }
        return true
    }

    private func received(_ bytes: ArraySlice<UInt8>) {
        var done: [(CheckedContinuation<CommandResult, Error>, CommandResult)] = []
        lock.withLock {
            buffer += bytes
            while let head = waiting.first, let start = buffer.firstRange(of: head.marker),
                  let newline = buffer[start.upperBound...].firstIndex(of: UInt8(ascii: "\n")) {
                let status = Int32(String(decoding: buffer[start.upperBound..<newline], as: UTF8.self)) ?? -1
                let output = String(decoding: buffer[..<start.lowerBound], as: UTF8.self)
                buffer.removeSubrange(...newline)
                waiting.removeFirst()
                done.append((head.continuation, CommandResult(status: status, stdout: output, stderr: "")))
            }
        }
        for (continuation, result) in done { continuation.resume(returning: result) }
    }

    /// Tart exited, or its output closed: what it printed last says why.
    private func ended() {
        let said = lock.withLock { String(decoding: buffer.suffix(500), as: UTF8.self) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").last.map(String.init) ?? ""
        end(ProxmacsError("The guest agent did not answer\(said.isEmpty ? "" : ": \(said)")"))
    }
}

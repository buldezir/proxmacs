import Foundation
import NIOCore
import NIOPosix
import XCTest
@testable import Proxmacs

/// `GuestLink` against a local stand-in for a guest's Screen Sharing port.
final class VNCHopTests: XCTestCase {
    private var server: EchoServer!

    override func setUp() async throws {
        server = try await EchoServer.start()
    }

    override func tearDown() async throws {
        await server?.stop()
    }

    func testNIOEchoBothWaysAndPeerCloseEndsTheStream() async throws {
        let link = try await GuestLink.connect(host: "127.0.0.1", port: server.port)
        let received = Task { await Self.collect(link.received) }

        try await link.send(Array("RFB 003.008\n".utf8))
        let echoed = await received.value
        XCTAssertEqual(echoed, Data("RFB 003.008\n".utf8))
        link.close()
    }

    func testNIOWriteAfterPeerCloseDoesNotCrash() async throws {
        let link = try await GuestLink.connect(host: "127.0.0.1", port: server.port)
        let received = Task { await Self.collect(link.received) }

        try await link.send(Array("RFB 003.008\n".utf8))
        _ = await received.value // the mock echoes and closes, so the stream has ended
        // Regression for the EPIPE crash: a write to a dead peer must surface as an error
        // or a dropped write. A SIGPIPE kill or an ObjC exception would end the test run.
        _ = try? await link.send(Array("after close".utf8))
        link.close()
    }

    func testNcHopEchoAndWriteAfterCloseDoesNotCrash() async throws {
        let hop = try NcHop(host: "127.0.0.1", port: server.port)
        let link = hop.link
        let received = Task { await Self.collect(link.received) }

        try await link.send(Array("RFB 003.008\n".utf8))
        let echoed = await received.value
        XCTAssertEqual(echoed, Data("RFB 003.008\n".utf8))
        // nc is gone once the mock closes; writing to its stdin must not raise SIGPIPE.
        _ = try? await link.send(Array("after close".utf8))
        link.close()
    }

    /// Each hop opens a socketpair and a pipe, and closing it must give both back: the app
    /// has about 256 descriptors, and every Display reconnect through the fallback opens a
    /// new hop. Before the fix, 10 hops left 20 descriptors behind.
    func testNcHopClosesItsDescriptors() async throws {
        func openDescriptors() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0 }
        // One hop first, so descriptors that are opened lazily on first use don't count.
        try NcHop(host: "127.0.0.1", port: server.port).close()
        try await Task.sleep(for: .milliseconds(300))
        let before = openDescriptors()
        for _ in 0..<10 {
            try NcHop(host: "127.0.0.1", port: server.port).close()
        }
        // The reading end closes on the read source's queue, and the mock's side of each
        // connection on its event loop.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertLessThan(openDescriptors() - before, 5)
    }

    func testClassifyDistinguishesPrivacyFromRefusal() {
        let refused = IOError(errnoCode: ECONNREFUSED, reason: "connect")
        guard case GuestLinkError.refused = GuestLink.classify(refused) else {
            return XCTFail("ECONNREFUSED should classify as refused")
        }
        let blocked = IOError(errnoCode: EHOSTUNREACH, reason: "connect")
        guard case GuestLinkError.localNetwork = GuestLink.classify(blocked) else {
            return XCTFail("EHOSTUNREACH should classify as Local Network privacy")
        }
        XCTAssertTrue(GuestLink.localNetworkPrivacy(blocked))
        XCTAssertFalse(GuestLink.localNetworkPrivacy(refused))
    }

    /// Happy-eyeballs can attach several errnos to one connect. If the unreachable attempt
    /// is listed first, a closed port used to be reported as Local Network privacy — which
    /// both misleads the user and skips the Screen Sharing auto-enable. `NIOConnectionError`
    /// cannot be built outside NIO, so the preference is tested on the codes alone.
    func testClassifyPrefersRefusalWhenHappyEyeballsTriesSeveralAddresses() {
        XCTAssertEqual(GuestLink.preferredErrno([EHOSTUNREACH, ECONNREFUSED]), ECONNREFUSED)
        // The reverse order must give the same answer.
        XCTAssertEqual(GuestLink.preferredErrno([ECONNREFUSED, EHOSTUNREACH]), ECONNREFUSED)
        XCTAssertEqual(GuestLink.preferredErrno([ENETUNREACH, ECONNREFUSED]), ECONNREFUSED)
        // With no refusal, the privacy errno is what the user must act on.
        XCTAssertEqual(GuestLink.preferredErrno([EHOSTUNREACH, ENETUNREACH]), EHOSTUNREACH)
        // Anything else is still reported rather than swallowed.
        XCTAssertEqual(GuestLink.preferredErrno([ETIMEDOUT, ECONNRESET]), ETIMEDOUT)
        XCTAssertNil(GuestLink.preferredErrno([]))
    }

    /// A port nothing listens on is "Screen Sharing is off", never Local Network privacy.
    func testClosedPortIsRefusedNotLocalNetwork() async throws {
        // Bind then release, so the port is definitely closed.
        let probe = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0).get()
        let port = probe.localAddress!.port!
        try await probe.close().get()

        do {
            _ = try await GuestLink.connect(host: "127.0.0.1", port: port)
            XCTFail("expected the connect to fail")
        } catch {
            guard case GuestLinkError.refused = error else {
                return XCTFail("expected .refused, got \(error)")
            }
        }
    }

    /// A WebSocket close reason longer than 123 bytes is dropped entirely by the browser
    /// (code 1006, empty reason) rather than truncated — measured against Chrome.
    func testCloseReasonsFitTheWebSocketLimit() {
        let long = String(repeating: "a", count: 300)
        XCTAssertEqual(VNCBridge.cap(long).utf8.count, VNCBridge.maxCloseReasonBytes)
        XCTAssertEqual(VNCBridge.cap("short"), "short")
        XCTAssertEqual(VNCBridge.cap(String(repeating: "a", count: 123)).utf8.count, 123)

        // "→" is three bytes: cutting mid-character would produce invalid UTF-8.
        let arrow = String(repeating: "→", count: 60)
        let capped = VNCBridge.cap(arrow)
        XCTAssertLessThanOrEqual(capped.utf8.count, VNCBridge.maxCloseReasonBytes)
        XCTAssertEqual(String(capped.utf8), capped, "must cut on a character boundary")
        XCTAssertFalse(capped.isEmpty)
    }

    /// Everything the mock sent before it closed, once the stream ends.
    private static func collect(_ stream: AsyncStream<Data>) async -> Data {
        var all = Data()
        for await data in stream { all.append(data) }
        return all
    }
}

/// Accepts one connection per client, echoes whatever it reads, then closes — so the
/// stream under test ends the way a dropped guest does.
private struct EchoServer {
    let channel: Channel
    let port: Int

    static func start() async throws -> EchoServer {
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(EchoOnce())
            }
            .bind(host: "127.0.0.1", port: 0).get()
        return EchoServer(channel: channel, port: channel.localAddress?.port ?? 0)
    }

    func stop() async {
        try? await channel.close()
    }

    private final class EchoOnce: ChannelInboundHandler, Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let buffer = unwrapInboundIn(data)
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(buffer)).whenComplete { _ in
                channel.close(promise: nil)
            }
        }
    }
}

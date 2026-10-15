import CryptoKit
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOPosix
import NIOSSL
import XCTest
@testable import Proxmacs

/// Runs `PBSH2Session` against a local stand-in for PBS: TLS with a pinned self-signed certificate,
/// an HTTP/1.1 upgrade to the backup protocol, then HTTP/2 requests on the same connection.
final class PBSSessionTests: XCTestCase {
    private var server: MockPBS!

    override func setUp() async throws {
        server = try await MockPBS.start()
    }

    override func tearDown() async throws {
        try await server?.stop()
    }

    func testUpgradeThenConcurrentRequests() async throws {
        let session = try await open()
        let data = try await session.json(.POST, "/fixed_index", query: [("archive-name", "disk.img.fidx")], body: Data("size=42".utf8))
        let echo = try XCTUnwrap(data as? [String: Any])
        XCTAssertEqual(echo["method"] as? String, "POST")
        XCTAssertEqual(echo["uri"] as? String, "/fixed_index?archive-name=disk.img.fidx")
        XCTAssertEqual(echo["body"] as? String, "size=42")

        // Chunk uploads run many streams at once on one connection.
        let uris = try await withThrowingTaskGroup(of: String.self) { group in
            for i in 0..<20 {
                group.addTask { (try await session.json(.GET, "/chunk/\(i)") as? [String: Any])?["uri"] as? String ?? "" }
            }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        XCTAssertEqual(uris, Set((0..<20).map { "/chunk/\($0)" }))

        let large = try await session.download("/large", query: [])
        XCTAssertEqual(large.count, MockPBS.largeSize)

        let missing = try await session.send(.GET, "/missing")
        XCTAssertEqual(missing.status, 404)
        await session.close()
    }

    func testRejectedUpgradeReportsServerMessage() async throws {
        do {
            _ = try await open(secret: "wrong")
            XCTFail("upgrade should be refused")
        } catch let error as PBSHTTPError {
            XCTAssertEqual(error.status, 401)
            XCTAssertEqual(error.errorDescription, "PBS returned HTTP 401: authentication failed")
        }
    }

    func testWrongFingerprintFails() async throws {
        var settings = server.settings
        settings.fingerprint = String(repeating: "00:", count: 31) + "00"
        do {
            _ = try await PBSH2Session.open(settings, secret: MockPBS.secret, protocolName: PBSH2Session.backupProtocol,
                                            path: "/api2/json/backup", query: [])
            XCTFail("a certificate that doesn't match the pin must be refused")
        } catch {}
    }

    private func open(secret: String = MockPBS.secret) async throws -> PBSH2Session {
        try await PBSH2Session.open(server.settings, secret: secret, protocolName: PBSH2Session.backupProtocol,
                                    path: "/api2/json/backup", query: [("store", "store")])
    }
}

private struct MockPBS {
    static let authId = "backup@pbs!test"
    static let secret = "s3cret"
    static let largeSize = 5 * 1024 * 1024 + 7

    let channel: Channel
    let settings: PBSSettings
    let directory: URL

    static func start() async throws -> MockPBS {
        let directory = FileManager.default.temporaryDirectory.appending(path: "proxmacs-pbs-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cert = directory.appending(path: "cert.pem"), key = directory.appending(path: "key.pem")
        try await Shell.check("/usr/bin/openssl", [
            "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-pkeyopt", "ec_param_enc:named_curve", "-nodes",
            "-keyout", key.path, "-out", cert.path, "-days", "1", "-subj", "/CN=pbs-test",
        ])
        let certificates = try NIOSSLCertificate.fromPEMFile(cert.path)
        let tls = try NIOSSLContext(configuration: .makeServerConfiguration(
            certificateChain: certificates.map { .certificate($0) },
            privateKey: .privateKey(try NIOSSLPrivateKey(file: key.path, format: .pem))
        ))
        let fingerprint = SHA256.hash(data: try certificates[0].toDERBytes()).map { String(format: "%02X", $0) }.joined(separator: ":")

        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let pipeline = channel.pipeline.syncOperations
                    try pipeline.addHandler(NIOSSLServerHandler(context: tls))
                    try pipeline.configureHTTPServerPipeline(withServerUpgrade: (upgraders: [Upgrader()], completionHandler: { _ in }))
                    try pipeline.addHandler(Unauthorized(), name: Unauthorized.name)
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let settings = PBSSettings(host: "127.0.0.1", port: channel.localAddress?.port ?? 0, datastore: "store",
                                   authId: authId, fingerprint: fingerprint)
        return MockPBS(channel: channel, settings: settings, directory: directory)
    }

    func stop() async throws {
        try await channel.close()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Accepts the backup protocol only with the right API token, then speaks HTTP/2.
    struct Upgrader: HTTPServerProtocolUpgrader, Sendable {
        let supportedProtocol = PBSH2Session.backupProtocol
        let requiredUpgradeHeaders: [String] = []

        func buildUpgradeResponse(channel: Channel, upgradeRequest: HTTPRequestHead,
                                  initialResponseHeaders: HTTPHeaders) -> EventLoopFuture<HTTPHeaders> {
            guard upgradeRequest.headers["Authorization"].first == "PBSAPIToken \(MockPBS.authId):\(MockPBS.secret)" else {
                return channel.eventLoop.makeFailedFuture(ProxmacsError("unauthorized"))
            }
            return channel.eventLoop.makeSucceededFuture(initialResponseHeaders)
        }

        func upgrade(context: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void> {
            context.eventLoop.makeCompletedFuture {
                let pipeline = context.pipeline.syncOperations
                pipeline.removeHandler(name: Unauthorized.name, promise: nil)
                _ = try pipeline.configureHTTP2Pipeline(mode: .server, connectionConfiguration: .init(), streamConfiguration: .init()) { stream in
                    stream.eventLoop.makeCompletedFuture {
                        try stream.pipeline.syncOperations.addHandlers([HTTP2FramePayloadToHTTP1ServerCodec(), Echo()])
                    }
                }
            }
        }
    }

    /// Answers requests that weren't upgraded, the way PBS refuses a bad token.
    final class Unauthorized: ChannelInboundHandler, RemovableChannelHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart
        static let name = "unauthorized"

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard case .end = unwrapInboundIn(data) else { return }
            MockPBS.respond(context, self, status: .unauthorized, body: Data(#"{"message":"authentication failed\n"}"#.utf8))
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {}  // the refused upgrade
    }

    /// Echoes each HTTP/2 request back as `{"data": {method, uri, body}}`.
    final class Echo: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private var head: HTTPRequestHead?
        private var body = ByteBuffer()

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head): self.head = head
            case .body(var buffer): body.writeBuffer(&buffer)
            case .end:
                let uri = head?.uri ?? ""
                if uri == "/missing" {
                    MockPBS.respond(context, self, status: .notFound, body: Data())
                } else if uri == "/large" {
                    MockPBS.respond(context, self, status: .ok, body: Data(repeating: 0xAB, count: MockPBS.largeSize))
                } else {
                    let echo: [String: Any] = ["method": head?.method.rawValue ?? "", "uri": uri, "body": String(buffer: body)]
                    MockPBS.respond(context, self, status: .ok, body: try! JSONSerialization.data(withJSONObject: ["data": echo]))
                }
            }
        }
    }

    static func respond<H: ChannelInboundHandler>(_ context: ChannelHandlerContext, _ handler: H, status: HTTPResponseStatus, body: Data)
        where H.OutboundOut == HTTPServerResponsePart {
        var headers = HTTPHeaders()
        headers.add(name: "content-length", value: String(body.count))
        context.write(handler.wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        context.write(handler.wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: body)))), promise: nil)
        context.writeAndFlush(handler.wrapOutboundOut(.end(nil)), promise: nil)
    }
}

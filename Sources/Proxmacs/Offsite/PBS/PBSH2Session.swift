import CryptoKit
import Foundation
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOPosix
import NIOSSL

struct PBSHTTPError: LocalizedError {
    var status: Int
    var body: String
    var errorDescription: String? {
        let message = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["message"] as? String
        return "PBS returned HTTP \(status): \((message ?? body).trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

/// One PBS protocol session: an HTTPS request upgraded (`Upgrade: proxmox-backup-protocol-v1` or the
/// reader variant) to HTTP/2 inside the same TLS connection, then plain HTTP/2 requests on top.
final class PBSH2Session: @unchecked Sendable {
    static let backupProtocol = "proxmox-backup-protocol-v1"
    static let readerProtocol = "proxmox-backup-reader-protocol-v1"

    private let channel: Channel
    private let multiplexer: NIOHTTP2Handler.StreamMultiplexer

    private init(channel: Channel, multiplexer: NIOHTTP2Handler.StreamMultiplexer) {
        self.channel = channel
        self.multiplexer = multiplexer
    }

    static func open(_ settings: PBSSettings, secret: String, protocolName: String, path: String, query: [(String, String)]) async throws -> PBSH2Session {
        let group = MultiThreadedEventLoopGroup.singleton
        let pin = settings.fingerprint.map(PBSFingerprint.normalize)
        var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
        // A pinned certificate is trusted as-is, whatever names it carries (PBS is often reached by IP).
        if pin != nil { tlsConfiguration.certificateVerification = .noHostnameVerification }
        let sslContext = try NIOSSLContext(configuration: tlsConfiguration)
        let upgraded = group.next().makePromise(of: NIOHTTP2Handler.StreamMultiplexer.self)
        let host = settings.host

        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(15))
            .channelInitializer { channel in
                do {
                    let isIP = host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
                    let tls: NIOSSLClientHandler
                    if let pin {
                        tls = try NIOSSLClientHandler(context: sslContext, serverHostname: isIP ? nil : host) { certificates, promise in
                            // Self-signed PBS certs: trust exactly the pinned leaf certificate.
                            let der = (try? certificates.first?.toDERBytes()) ?? []
                            let actual = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
                            promise.succeed(actual == pin ? .certificateVerified : .failed)
                        }
                    } else {
                        tls = try NIOSSLClientHandler(context: sslContext, serverHostname: isIP ? nil : host)
                    }
                    let pipeline = channel.pipeline.syncOperations
                    try pipeline.addHandler(tls)
                    try pipeline.addHTTPClientHandlers(
                        leftOverBytesStrategy: .forwardBytes,
                        withClientUpgrade: (upgraders: [PBSUpgrader(protocolName: protocolName, promise: upgraded)], completionHandler: { _ in })
                    )
                    try pipeline.addHandler(UpgradeFailureHandler(promise: upgraded), name: UpgradeFailureHandler.name)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        let channel = try await bootstrap.connect(host: settings.host, port: settings.port).get()
        channel.closeFuture.whenComplete { _ in upgraded.fail(ProxmacsError("PBS connection closed during protocol upgrade")) }

        var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: path + encodeQuery(query))
        head.headers.add(name: "Host", value: "\(settings.host):\(settings.port)")
        head.headers.add(name: "Authorization", value: "PBSAPIToken \(settings.authId):\(secret)")
        head.headers.add(name: "User-Agent", value: "proxmacs/0.1")
        channel.write(HTTPClientRequestPart.head(head), promise: nil)
        try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()

        do {
            let multiplexer = try await upgraded.futureResult.get()
            return PBSH2Session(channel: channel, multiplexer: multiplexer)
        } catch {
            try? await channel.close().get()
            throw error
        }
    }

    func close() async {
        try? await channel.close().get()
    }

    /// Sends one request on a new HTTP/2 stream and returns status + body.
    func send(_ method: HTTPMethod, _ path: String, query: [(String, String)] = [], body: Data? = nil,
              contentType: String = "application/x-www-form-urlencoded") async throws -> (status: Int, body: Data) {
        let response = channel.eventLoop.makePromise(of: (HTTPResponseHead, ByteBuffer).self)
        let streamPromise = channel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: streamPromise) { stream in
            stream.eventLoop.makeCompletedFuture {
                try stream.pipeline.syncOperations.addHandlers([
                    HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https),
                    ResponseCollector(promise: response),
                ])
            }
        }
        let stream = try await streamPromise.futureResult.get()

        var head = HTTPRequestHead(version: .http2, method: method, uri: path + Self.encodeQuery(query))
        head.headers.add(name: "host", value: "localhost")
        head.headers.add(name: "content-type", value: contentType)
        head.headers.add(name: "content-length", value: String(body?.count ?? 0))
        stream.write(HTTPClientRequestPart.head(head), promise: nil)
        if let body, !body.isEmpty {
            stream.write(HTTPClientRequestPart.body(.byteBuffer(ByteBuffer(bytes: body))), promise: nil)
        }
        try await stream.writeAndFlush(HTTPClientRequestPart.end(nil)).get()

        let (responseHead, buffer) = try await response.futureResult.get()
        return (Int(responseHead.status.code), Data(buffer.readableBytesView))
    }

    /// Sends a request and returns the `data` member of the JSON response (PBS API convention).
    @discardableResult
    func json(_ method: HTTPMethod, _ path: String, query: [(String, String)] = [], body: Data? = nil,
              contentType: String = "application/x-www-form-urlencoded") async throws -> Any? {
        let (status, data) = try await send(method, path, query: query, body: body, contentType: contentType)
        guard (200..<300).contains(status) else { throw PBSHTTPError(status: status, body: String(decoding: data, as: UTF8.self)) }
        if data.isEmpty { return nil }
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return (object as? [String: Any])?["data"]
    }

    /// Downloads a raw file body, throwing on non-2xx.
    func download(_ path: String, query: [(String, String)]) async throws -> Data {
        let (status, data) = try await send(.GET, path, query: query)
        guard (200..<300).contains(status) else { throw PBSHTTPError(status: status, body: String(decoding: data, as: UTF8.self)) }
        return data
    }

    static func encodeQuery(_ query: [(String, String)]) -> String {
        guard !query.isEmpty else { return "" }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return "?" + query.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }
}

enum PBSFingerprint {
    /// "AA:BB:…" → "aabb…"
    static func normalize(_ fingerprint: String) -> String {
        fingerprint.lowercased().filter { $0.isHexDigit }
    }
}

// MARK: - Pipeline pieces

private final class PBSUpgrader: NIOHTTPClientProtocolUpgrader, @unchecked Sendable {
    let supportedProtocol: String
    let requiredUpgradeHeaders: [String] = []
    private let promise: EventLoopPromise<NIOHTTP2Handler.StreamMultiplexer>

    init(protocolName: String, promise: EventLoopPromise<NIOHTTP2Handler.StreamMultiplexer>) {
        supportedProtocol = protocolName
        self.promise = promise
    }

    func addCustom(upgradeRequestHeaders: inout HTTPHeaders) {}

    func shouldAllowUpgrade(upgradeResponse: HTTPResponseHead) -> Bool { true }

    func upgrade(context: ChannelHandlerContext, upgradeResponse: HTTPResponseHead) -> EventLoopFuture<Void> {
        let channel = context.channel
        let promise = self.promise
        // The failure handler only understands HTTP/1 parts; drop it before HTTP/2 frames flow.
        return context.pipeline.removeHandler(name: UpgradeFailureHandler.name).flatMapThrowing {
            var connection = NIOHTTP2Handler.ConnectionConfiguration()
            connection.initialSettings = [
                HTTP2Setting(parameter: .maxConcurrentStreams, value: 100),
                HTTP2Setting(parameter: .initialWindowSize, value: (1 << 31) - 2),
                HTTP2Setting(parameter: .maxFrameSize, value: 4 * 1024 * 1024),
            ]
            var stream = NIOHTTP2Handler.StreamConfiguration()
            stream.targetWindowSize = 32 * 1024 * 1024
            // PBS never opens streams towards the client.
            promise.succeed(try channel.pipeline.syncOperations.configureHTTP2Pipeline(
                mode: .client, connectionConfiguration: connection, streamConfiguration: stream
            ) { $0.close() })
        }
    }
}

/// Catches a non-101 answer to the upgrade request (e.g. 401/400) and fails the session with its body.
private final class UpgradeFailureHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    static let name = "pbs-upgrade-failure"

    private let promise: EventLoopPromise<NIOHTTP2Handler.StreamMultiplexer>
    private var status = 0
    private var body = ByteBuffer()

    init(promise: EventLoopPromise<NIOHTTP2Handler.StreamMultiplexer>) { self.promise = promise }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): status = Int(head.status.code)
        case .body(var buffer): body.writeBuffer(&buffer)
        case .end:
            promise.fail(PBSHTTPError(status: status, body: String(buffer: body)))
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.close(promise: nil)
    }
}

private final class ResponseCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    private let promise: EventLoopPromise<(HTTPResponseHead, ByteBuffer)>
    private var head: HTTPResponseHead?
    private var body = ByteBuffer()
    private var done = false

    init(promise: EventLoopPromise<(HTTPResponseHead, ByteBuffer)>) { self.promise = promise }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): self.head = head
        case .body(var buffer): body.writeBuffer(&buffer)
        case .end:
            done = true
            promise.succeed((head ?? HTTPResponseHead(version: .http2, status: .internalServerError), body))
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !done { done = true; promise.fail(error) }
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !done { done = true; promise.fail(ProxmacsError("PBS stream closed before response completed")) }
        context.fireChannelInactive()
    }
}

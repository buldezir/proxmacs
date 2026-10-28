import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTLS
import HummingbirdWebSocket
import NIOCore
import NIOSSL
import Observation

typealias WebContext = BasicWebSocketRequestContext

/// Proxmox-style web UI: HTTPS (self-signed) on :8006 by default, password login, JSON API,
/// serial console over WebSocket. Runs inside the menubar app or `Proxmacs cli serve`.
@MainActor
@Observable
final class WebServer {
    static let shared = WebServer()

    private(set) var running = false
    private(set) var url: String?
    private(set) var lastError: String?
    private var task: Task<Void, Never>?

    func start(state: AppState) {
        stop()
        let settings = WebSettings.load()
        guard settings.enabled else { return }
        let host = settings.bind == "127.0.0.1" ? "127.0.0.1" : ProcessInfo.processInfo.hostName
        url = "\(settings.scheme)://\(host):\(settings.port)"
        task = Task.detached {
            do {
                if settings.tls { try await WebCertificate.ensure() }
                let app = try Self.makeApplication(state: state, settings: settings)
                await MainActor.run { WebServer.shared.running = true; WebServer.shared.lastError = nil }
                try await app.runService(gracefulShutdownSignals: [])
            } catch {
                await MainActor.run { WebServer.shared.lastError = String(describing: error) }
            }
            await MainActor.run { WebServer.shared.running = false }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        running = false
    }

    /// Blocks (for `cli serve`) until the server stops.
    func wait() async {
        await task?.value
    }

    nonisolated static func assetsDirectory() -> String {
        if let bundled = Bundle.main.resourceURL?.appending(path: "WebAssets"),
           FileManager.default.fileExists(atPath: bundled.appending(path: "index.html").path) {
            return bundled.path
        }
        // Development: the React build in the source tree (`npm --prefix web run build`).
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "web/dist").path
    }

    nonisolated static func makeApplication(state: AppState, settings: WebSettings) throws -> some ApplicationProtocol {
        let router = Router(context: WebContext.self)
        router.add(middleware: SecurityHeadersMiddleware(webSocketScheme: settings.tls ? "wss" : "ws"))
        router.add(middleware: AuthMiddleware())
        router.add(middleware: FileMiddleware(assetsDirectory(), searchForIndexHtml: true))
        router.get("/llms.txt") { _, _ in LLMsTxt.response() }
        WebAPI(state: state, settings: settings).register(on: router)

        let configuration = ApplicationConfiguration(address: .hostname(settings.bind, port: settings.port), serverName: "Proxmacs")
        guard settings.tls else {
            return Application(router: router, server: .http1WebSocketUpgrade(webSocketRouter: router), configuration: configuration)
        }
        let certPEM = try [UInt8](Data(contentsOf: WebCertificate.cert))
        let keyPEM = try [UInt8](Data(contentsOf: WebCertificate.key))
        let tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: try NIOSSLCertificate.fromPEMBytes(certPEM).map { .certificate($0) },
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: keyPEM, format: .pem))
        )
        return Application(router: router, server: try .tls(.http1WebSocketUpgrade(webSocketRouter: router), tlsConfiguration: tls),
                           configuration: configuration)
    }
}

// MARK: - Middleware

struct AuthMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let path = request.uri.path
        guard path.hasPrefix("/api/"), path != "/api/login", path != "/api/session" else {
            return try await next(request, context)
        }
        // Programs use an API key instead of a login session. Browsers never send this header on their own,
        // so the CSRF rule below doesn't apply.
        if let authorization = request.headers[.authorization] {
            let token = authorization.hasPrefix("Bearer ") ? String(authorization.dropFirst(7)).trimmingCharacters(in: .whitespaces) : ""
            guard APIKeyStore.shared.authenticate(token) != nil else {
                return API.error("Invalid API key (expected Authorization: Bearer pmx_…)", status: .unauthorized)
            }
            return try await next(request, context)
        }
        guard await SessionStore.shared.isValid(request.cookies[SessionStore.cookieName]?.value) else {
            return API.error("Not authenticated", status: .unauthorized)
        }
        // CSRF: browsers can't send a JSON content type cross-origin without a CORS preflight we never allow.
        if request.method != .get, request.method != .head,
           request.headers[.contentType]?.hasPrefix("application/json") != true {
            return API.error("Mutating requests must use Content-Type: application/json", status: .badRequest)
        }
        return try await next(request, context)
    }
}

struct SecurityHeadersMiddleware<Context: RequestContext>: RouterMiddleware {
    var webSocketScheme = "wss"

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        var response = try await next(request, context)
        let host = request.head.authority ?? "localhost"
        response.headers[.contentSecurityPolicy] =
            "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' \(webSocketScheme)://\(host); frame-ancestors 'none'"
        response.headers[.xFrameOptions] = "DENY"
        response.headers[.xContentTypeOptions] = "nosniff"
        response.headers[.referrerPolicy] = "no-referrer"
        let path = request.uri.path
        if path.hasPrefix("/api/") {
            response.headers[.cacheControl] = "no-store"
        } else if path.hasPrefix("/assets/") {
            // Vite names bundles by content hash.
            response.headers[.cacheControl] = "public, max-age=31536000, immutable"
        } else if response.headers[.cacheControl] == nil {
            // index.html names the current bundles: revalidate it, or an upgrade keeps serving the old UI.
            response.headers[.cacheControl] = "no-cache"
        }
        return response
    }
}

// MARK: - JSON helpers

enum API {
    static func json(_ value: Any, status: HTTPResponse.Status = .ok) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data("null".utf8)
        return Response(status: status, headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    static func error(_ message: String, status: HTTPResponse.Status = .badRequest) -> Response {
        json(["error": message], status: status)
    }

    static func noContent() -> Response { Response(status: .noContent) }

    static func body(_ request: Request) async throws -> [String: Any] {
        let buffer = try await request.body.collect(upTo: 1 << 20)
        guard buffer.readableBytes > 0 else { return [:] }
        return (try JSONSerialization.jsonObject(with: Data(buffer.readableBytesView)) as? [String: Any]) ?? [:]
    }

    /// Runs a handler, mapping thrown errors to `{"error": …}` responses.
    static func guarded(_ body: () async throws -> Response) async -> Response {
        do {
            return try await body()
        } catch let error as APIError {
            return API.error(error.message, status: error.status)
        } catch {
            return API.error(error.localizedDescription)
        }
    }
}

struct APIError: Error {
    var message: String
    var status: HTTPResponse.Status = .badRequest
    static func notFound(_ what: String) -> APIError { APIError(message: "\(what) not found", status: .notFound) }
}

extension HTTPField.Name {
    static let xFrameOptions = Self("X-Frame-Options")!
    static let xContentTypeOptions = Self("X-Content-Type-Options")!
    static let referrerPolicy = Self("Referrer-Policy")!
}

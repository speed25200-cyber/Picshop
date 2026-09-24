#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import PicshopIntent

/// Claude over URLSession. One ephemeral session for the whole app (no cache, no
/// cookies), so the HTTP/2 connection opened by the warm-up is reused by every turn.
///
/// `stream` yields the body in line-sized chunks as they arrive, blank lines
/// included (never `AsyncBytes.lines`, which drops them). A non-2xx answer is read
/// and thrown as `ClaudeAPIError`; URL errors become `LiveBrainError`. Cancelling
/// the consuming task cancels the HTTP request.
final class URLSessionClaudeTransport: ClaudeTransport, @unchecked Sendable {
    enum UploadEvent: Sendable, Equatable {
        case started
        case finished(success: Bool)
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// Called for requests that carry an image: when the upload starts and how it ended.
    private let onImageUpload: (@Sendable (UploadEvent) -> Void)?

    init(onImageUpload: (@Sendable (UploadEvent) -> Void)? = nil) {
        self.onImageUpload = onImageUpload
    }

    func stream(_ request: ClaudeHTTPRequest) -> AsyncThrowingStream<Data, Error> {
        let onImageUpload = request.carriesImage ? self.onImageUpload : nil
        return AsyncThrowingStream { continuation in
            let task = Task {
                var uploadOpen = false
                do {
                    let urlRequest = try Self.urlRequest(for: request)
                    if let onImageUpload {
                        uploadOpen = true
                        onImageUpload(.started)
                    }
                    let (bytes, response) = try await Self.session.bytes(for: urlRequest)
                    let http = response as? HTTPURLResponse
                    let status = http?.statusCode ?? 0
                    if uploadOpen {
                        uploadOpen = false
                        onImageUpload?(.finished(success: (200..<300).contains(status)))
                    }
                    guard (200..<300).contains(status) else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count >= 65_536 { break }
                        }
                        throw Self.apiError(status: status, headers: Self.headers(of: http), body: body)
                    }
                    var chunk = Data()
                    chunk.reserveCapacity(2048)
                    for try await byte in bytes {
                        chunk.append(byte)
                        // A line at a time: the SSE parser only ever needs complete lines.
                        if byte == 0x0A || chunk.count >= 16_384 {
                            continuation.yield(chunk)
                            chunk = Data()
                            chunk.reserveCapacity(2048)
                        }
                    }
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    if uploadOpen { onImageUpload?(.finished(success: false)) }
                    continuation.finish(throwing: Self.mapped(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func send(_ request: ClaudeHTTPRequest) async throws -> (status: Int, headers: [String: String], body: Data) {
        do {
            let (data, response) = try await Self.session.data(for: Self.urlRequest(for: request))
            let http = response as? HTTPURLResponse
            return (http?.statusCode ?? 0, Self.headers(of: http), data)
        } catch {
            throw Self.mapped(error)
        }
    }

    // MARK: Helpers

    static func urlRequest(for request: ClaudeHTTPRequest) throws -> URLRequest {
        guard let url = URL(string: request.url) else { throw LiveBrainError.badRequest(requestID: nil, message: "bad url") }
        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeout > 0 ? request.timeout : 30)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.httpBody = request.body
        return urlRequest
    }

    /// Lower-cased header names.
    static func headers(of response: HTTPURLResponse?) -> [String: String] {
        var headers: [String: String] = [:]
        for (name, value) in response?.allHeaderFields ?? [:] {
            headers[String(describing: name).lowercased()] = String(describing: value)
        }
        return headers
    }

    /// {"type":"error","error":{"type","message"},"request_id"} plus the request-id and retry-after headers.
    static func apiError(status: Int, headers: [String: String], body: Data) -> ClaudeAPIError {
        var type = "http_\(status)"
        var message = HTTPURLResponse.localizedString(forStatusCode: status)
        var requestID = headers["request-id"]
        if let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            if let error = object["error"] as? [String: Any] {
                type = (error["type"] as? String) ?? type
                message = (error["message"] as? String) ?? message
            }
            requestID = (object["request_id"] as? String) ?? requestID
        }
        let retryAfter = headers["retry-after"].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return ClaudeAPIError(status: status, type: type, message: APIKeyFormat.redact(String(message.prefix(300))),
                              requestID: requestID, retryAfter: retryAfter)
    }

    static func mapped(_ error: Error) -> Error {
        if error is CancellationError || error is ClaudeAPIError || error is LiveBrainError { return error }
        guard let urlError = error as? URLError else { return LiveBrainError.network(String(describing: type(of: error))) }
        switch urlError.code {
        case .cancelled: return CancellationError()
        case .timedOut: return LiveBrainError.timeout(stage: "transport")
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff, .cannotFindHost,
             .cannotConnectToHost, .dnsLookupFailed:
            return LiveBrainError.network("offline")
        default:
            return LiveBrainError.network("url error \(urlError.code.rawValue)")
        }
    }
}
#endif

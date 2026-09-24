#if canImport(SwiftUI) && canImport(UIKit) && DEBUG
import Foundation
import PicshopIntent

/// Debug builds: answers Claude requests with the fault picked in Diagnostic Live
/// (LiveDebugModel.injectedFault) instead of the network, so every failure path
/// can be walked on the simulator. With no fault, requests go to `base`.
///
/// Faults: 401, 402, 429 (retry-after 30), 429:1 (retry-after 1), 529, timeout
/// (a stall), refusal (an SSE stream that stops with stop_reason refusal), offline.
final class FaultInjectingTransport: ClaudeTransport, @unchecked Sendable {
    private let base: any ClaudeTransport

    init(base: any ClaudeTransport) {
        self.base = base
    }

    func stream(_ request: ClaudeHTTPRequest) -> AsyncThrowingStream<Data, Error> {
        guard let fault = LiveFaultSwitch.shared.current else { return base.stream(request) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    switch fault {
                    case "timeout":
                        // A stall: nothing arrives until the brain's watchdog gives up.
                        try await Task.sleep(nanoseconds: 60_000_000_000)
                        continuation.finish(throwing: LiveBrainError.timeout(stage: "transport"))
                    case "refusal":
                        try await Task.sleep(nanoseconds: 250_000_000)
                        for line in Self.refusalStream.split(separator: "\n", omittingEmptySubsequences: false) {
                            continuation.yield(Data((String(line) + "\n").utf8))
                        }
                        continuation.finish()
                    case "offline":
                        continuation.finish(throwing: LiveBrainError.network("offline"))
                    default:
                        try await Task.sleep(nanoseconds: 150_000_000)
                        continuation.finish(throwing: Self.apiError(fault))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func send(_ request: ClaudeHTTPRequest) async throws -> (status: Int, headers: [String: String], body: Data) {
        guard let fault = LiveFaultSwitch.shared.current else { return try await base.send(request) }
        switch fault {
        case "timeout":
            try await Task.sleep(nanoseconds: 12_000_000_000)
            throw LiveBrainError.timeout(stage: "transport")
        case "offline":
            throw LiveBrainError.network("offline")
        case "refusal":
            return try await base.send(request)
        default:
            let error = Self.apiError(fault)
            var headers = ["request-id": "req_fault_injected"]
            if let retryAfter = error.retryAfter { headers["retry-after"] = String(Int(retryAfter)) }
            let body = "{\"type\":\"error\",\"error\":{\"type\":\"\(error.type)\",\"message\":\"\(error.message)\"},\"request_id\":\"req_fault_injected\"}"
            return (error.status ?? 500, headers, Data(body.utf8))
        }
    }

    static func apiError(_ fault: String) -> ClaudeAPIError {
        func error(_ status: Int, _ type: String, _ message: String, _ retryAfter: Double? = nil) -> ClaudeAPIError {
            ClaudeAPIError(status: status, type: type, message: message, requestID: "req_fault_injected", retryAfter: retryAfter)
        }
        switch fault {
        case "401": return error(401, "authentication_error", "invalid x-api-key")
        case "402": return error(402, "billing_error", "Your credit balance is too low.")
        case "429:1": return error(429, "rate_limit_error", "Rate limited (injected).", 1)
        case "429": return error(429, "rate_limit_error", "Rate limited (injected).", 30)
        case "529": return error(529, "overloaded_error", "Overloaded (injected).")
        default: return error(500, "api_error", "Injected fault \(fault).")
        }
    }

    /// A response Claude declined: no content, stop_reason refusal.
    static let refusalStream = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_fault","type":"message","role":"assistant","model":"claude-opus-5","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":12,"output_tokens":1}}}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"refusal","stop_sequence":null},"usage":{"output_tokens":1}}

    event: message_stop
    data: {"type":"message_stop"}


    """
}
#endif

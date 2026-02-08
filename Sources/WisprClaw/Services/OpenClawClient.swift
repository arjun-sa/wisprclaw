import Foundation

final class OpenClawClient {
    private let protocolVersion = 3

    func send(text: String) async throws -> String {
        let baseURL = UserDefaults.standard.string(forKey: "openclawURL") ?? "http://127.0.0.1:18789"
        let token = UserDefaults.standard.string(forKey: "openclawToken")
            ?? EnvLoader.value(for: "GATEWAY_TOKEN")
            ?? EnvLoader.value(for: "OPENCLAW_GATEWAY_TOKEN")
            ?? ""

        let wsURLString = baseURL
            .replacingOccurrences(of: "http://", with: "ws://")
            .replacingOccurrences(of: "https://", with: "wss://")

        guard let url = URL(string: wsURLString) else {
            throw URLError(.badURL)
        }

        return try await runAgent(url: url, token: token, message: text)
    }

    private func runAgent(url: URL, token: String, message: String) async throws -> String {
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()

        defer { task.cancel(with: .goingAway, reason: nil) }

        let bridge = MessageBridge()
        let receiveTask = Task {
            await receiveLoop(task: task, bridge: bridge)
        }

        defer { receiveTask.cancel() }

        // Wait for connect.challenge (required for device identity)
        let nonce = try await bridge.waitForChallenge()

        // Send connect with device identity
        try await sendConnect(task: task, token: token, nonce: nonce, bridge: bridge)

        // Send agent request
        let agentPayload = try await sendAgentRequest(task: task, message: message, bridge: bridge)

        if agentPayload["status"] as? String == "error" {
            let errorMsg = agentPayload["error"] as? String ?? agentPayload["message"] as? String ?? "Agent failed"
            throw NSError(domain: "OpenClaw", code: 0, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }

        let result = agentPayload["result"] as? [String: Any] ?? agentPayload
        return Self.extractPayloadText(from: result)
    }

    private func receiveLoop(task: URLSessionWebSocketTask, bridge: MessageBridge) async {
        while !Task.isCancelled {
            do {
                let wsMessage = try await task.receive()
                let raw: String
                switch wsMessage {
                case .string(let s): raw = s
                case .data(let d): raw = String(data: d, encoding: .utf8) ?? ""
                @unknown default: continue
                }

                if let data = raw.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    await bridge.deliver(parsed)
                }
            } catch {
                await bridge.deliverError(error)
                break
            }
        }
    }

    private func deviceParams(deviceId: String, publicKey: String, signature: String, signedAtMs: Int64, nonce: String?) -> [String: Any] {
        var d: [String: Any] = [
            "id": deviceId,
            "publicKey": publicKey,
            "signature": signature,
            "signedAt": signedAtMs
        ]
        if let n = nonce { d["nonce"] = n }
        return d
    }

    private func sendConnect(task: URLSessionWebSocketTask, token: String, nonce: String?, bridge: MessageBridge) async throws {
        let connectId = UUID().uuidString
        let scopes = ["operator.read", "operator.write"]
        let role = "operator"
        let clientId = "openclaw-macos"
        let clientMode = "ui"
        let signedAtMs = Int64(Date().timeIntervalSince1970 * 1000)

        let (deviceId, publicKeyBase64Url, privateKey) = DeviceIdentity.loadOrCreate()

        let payloadString: String
        if let nonce = nonce {
            payloadString = ["v2", deviceId, clientId, clientMode, role, scopes.joined(separator: ","), String(signedAtMs), token, nonce].joined(separator: "|")
        } else {
            payloadString = ["v1", deviceId, clientId, clientMode, role, scopes.joined(separator: ","), String(signedAtMs), token].joined(separator: "|")
        }
        let signature = DeviceIdentity.signPayload(payloadString, privateKey: privateKey)

        var params: [String: Any] = [
            "minProtocol": protocolVersion,
            "maxProtocol": protocolVersion,
            "client": [
                "id": clientId,
                "version": "1.0",
                "platform": "macos",
                "mode": clientMode
            ] as [String: Any],
            "role": role,
            "scopes": scopes,
            "caps": [] as [String],
            "commands": [] as [String],
            "permissions": [:] as [String: Bool],
            "locale": "en-US",
            "userAgent": "wisprclaw/1.0",
            "device": deviceParams(deviceId: deviceId, publicKey: publicKeyBase64Url, signature: signature, signedAtMs: signedAtMs, nonce: nonce)
        ]

        if !token.isEmpty {
            params["auth"] = ["token": token]
        }

        let connectReq: [String: Any] = [
            "type": "req",
            "id": connectId,
            "method": "connect",
            "params": params
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: connectReq),
              let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "OpenClaw", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to encode connect request"])
        }

        task.send(.string(json)) { _ in }

        let response = try await bridge.waitForResponse(id: connectId)
        guard response["type"] as? String == "hello-ok" else {
            throw NSError(domain: "OpenClaw", code: 0, userInfo: [NSLocalizedDescriptionKey: "Connect failed"])
        }
    }

    private func sendAgentRequest(task: URLSessionWebSocketTask, message: String, bridge: MessageBridge) async throws -> [String: Any] {
        let reqId = UUID().uuidString
        let idempotencyKey = UUID().uuidString

        let params: [String: Any] = [
            "message": message,
            "idempotencyKey": idempotencyKey,
            "deliver": false,
            "agentId": "main"
        ]

        let req: [String: Any] = [
            "type": "req",
            "id": reqId,
            "method": "agent",
            "params": params
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: req),
              let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "OpenClaw", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to encode agent request"])
        }

        task.send(.string(json)) { _ in }

        // Agent returns: first "accepted", then final with status "ok" or "error" (bridge ignores accepted)
        return try await bridge.waitForResponse(id: reqId)
    }

    private static func extractPayloadText(from result: [String: Any]) -> String {
        if let payloads = result["payloads"] as? [[String: Any]] {
            let texts = payloads.compactMap { $0["text"] as? String }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (result["summary"] as? String) ?? ""
    }
}

// Bridges WebSocket messages to awaiting continuations
private actor MessageBridge {
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var challengeContinuation: CheckedContinuation<String?, Error>?
    private var bufferedNonce: String?
    private var challengeBuffered = false

    func deliver(_ message: [String: Any]) {
        if message["type"] as? String == "event" {
            let event = message["event"] as? String ?? ""
            if event == "connect.challenge" {
                let payload = message["payload"] as? [String: Any]
                let nonce = payload?["nonce"] as? String
                if let cont = challengeContinuation {
                    challengeContinuation = nil
                    cont.resume(returning: nonce)
                } else {
                    // Challenge arrived before waitForChallenge — buffer it
                    bufferedNonce = nonce
                    challengeBuffered = true
                }
            }
            return
        }

        if message["type"] as? String == "res" {
            let id = message["id"] as? String ?? ""
            guard let cont = pending[id] else { return }

            let payload = message["payload"] as? [String: Any] ?? [:]
            let status = payload["status"] as? String
            let ok = message["ok"] as? Bool ?? false

            // Agent sends two responses: first "accepted", then final "ok"/"error". Don't resolve on accepted.
            if status == "accepted" {
                return
            }

            pending.removeValue(forKey: id)
            if ok {
                cont.resume(returning: payload)
            } else {
                let errorMsg = (message["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
                cont.resume(throwing: NSError(domain: "OpenClaw", code: 0, userInfo: [NSLocalizedDescriptionKey: errorMsg]))
            }
        }
    }

    func deliverError(_ error: Error) {
        challengeContinuation?.resume(throwing: error)
        challengeContinuation = nil
        for (_, cont) in pending {
            cont.resume(throwing: error)
        }
        pending.removeAll()
    }

    func waitForChallenge() async throws -> String? {
        // If the challenge already arrived before we started waiting, return it immediately
        if challengeBuffered {
            return bufferedNonce
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String?, Error>) in
            challengeContinuation = cont
        }
    }

    func waitForResponse(id: String) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
            pending[id] = cont
        }
    }
}

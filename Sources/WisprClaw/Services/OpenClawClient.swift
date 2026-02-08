import Foundation

final class OpenClawClient {
    private let protocolVersion = 3

    private var wsTask: URLSessionWebSocketTask?
    private var bridge: MessageBridge?
    private var receiveLoopTask: Task<Void, Never>?
    private var isConnected = false

    deinit {
        disconnect()
    }

    func send(text: String) async throws -> String {
        try await ensureConnected()

        do {
            return try await sendAgentAndExtract(message: text)
        } catch {
            // On connection-level failure, reconnect once and retry
            guard isConnectionError(error) else { throw error }
            isConnected = false
            try await ensureConnected()
            return try await sendAgentAndExtract(message: text)
        }
    }

    private func sendAgentAndExtract(message: String) async throws -> String {
        let agentPayload = try await sendAgentRequest(message: message)

        if agentPayload["status"] as? String == "error" {
            let errorMsg = agentPayload["error"] as? String ?? agentPayload["message"] as? String ?? "Agent failed"
            throw NSError(domain: "OpenClaw", code: 0, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }

        let result = agentPayload["result"] as? [String: Any] ?? agentPayload
        return Self.extractPayloadText(from: result)
    }

    private func ensureConnected() async throws {
        if isConnected, let ws = wsTask, ws.state == .running {
            return
        }

        disconnect()

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

        let ws = URLSession.shared.webSocketTask(with: url)
        ws.resume()

        let newBridge = MessageBridge()
        let loopTask = Task {
            await self.receiveLoop(task: ws, bridge: newBridge)
        }

        wsTask = ws
        bridge = newBridge
        receiveLoopTask = loopTask

        do {
            let nonce = try await newBridge.waitForChallenge()
            try await sendConnect(token: token, nonce: nonce)
            isConnected = true
        } catch {
            disconnect()
            throw error
        }
    }

    func disconnect() {
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        bridge = nil
        isConnected = false
    }

    private func isConnectionError(_ error: Error) -> Bool {
        if (error as? URLError) != nil { return true }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain { return true }
        // WebSocket close / cancellation errors
        let code = (error as NSError).code
        if nsError.domain == "NSURLErrorDomain" || code == -1005 || code == -1009 { return true }
        return false
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
                isConnected = false
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

    private func sendConnect(token: String, nonce: String?) async throws {
        guard let task = wsTask, let bridge = bridge else {
            throw NSError(domain: "OpenClaw", code: 0, userInfo: [NSLocalizedDescriptionKey: "No active WebSocket connection"])
        }
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

    private func sendAgentRequest(message: String) async throws -> [String: Any] {
        guard let task = wsTask, let bridge = bridge else {
            throw NSError(domain: "OpenClaw", code: 0, userInfo: [NSLocalizedDescriptionKey: "No active WebSocket connection"])
        }
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

    func reset() {
        challengeContinuation = nil
        bufferedNonce = nil
        challengeBuffered = false
        for (_, cont) in pending {
            cont.resume(throwing: CancellationError())
        }
        pending.removeAll()
    }
}

import Foundation
import CryptoKit

/// Device identity for OpenClaw gateway authentication.
/// Persists to ~/.openclaw/wisprclaw-device.json
enum DeviceIdentity {
   struct Storage: Codable {
        let deviceId: String
        let publicKeyBase64: String
        let privateKeyBase64: String
    }

    static func loadOrCreate() -> (deviceId: String, publicKeyBase64Url: String, privateKey: Curve25519.Signing.PrivateKey) {
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw")
            .appendingPathComponent("wisprclaw-device.json")

        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode(Storage.self, from: data),
           let privKeyData = Data(base64Encoded: stored.privateKeyBase64),
           let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privKeyData) {
            let deviceId = stored.deviceId
            let publicKeyBase64Url = base64UrlEncode(privateKey.publicKey.rawRepresentation)
            return (deviceId, publicKeyBase64Url, privateKey)
        }

        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKeyRaw = privateKey.publicKey.rawRepresentation
        let deviceId = SHA256.hash(data: publicKeyRaw).map { String(format: "%02x", $0) }.joined()
        let publicKeyBase64Url = base64UrlEncode(publicKeyRaw)

        let stored = Storage(
            deviceId: deviceId,
            publicKeyBase64: Data(publicKeyRaw).base64EncodedString(),
            privateKeyBase64: privateKey.rawRepresentation.base64EncodedString()
        )

        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(stored).write(to: fileURL)

        return (deviceId, publicKeyBase64Url, privateKey)
    }

    static func signPayload(_ payload: String, privateKey: Curve25519.Signing.PrivateKey) -> String {
        let data = Data(payload.utf8)
        let signature = try! privateKey.signature(for: data)
        return base64UrlEncode(Data(signature))
    }

    private static func base64UrlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

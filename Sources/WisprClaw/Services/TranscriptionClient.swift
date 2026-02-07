import Foundation

final class TranscriptionClient {
    struct TranscriptionResponse: Decodable {
        let text: String
    }

    struct ErrorResponse: Decodable {
        let detail: String
    }

    func transcribe(fileURL: URL, gatewayURL: String) async throws -> String {
        guard let url = URL(string: gatewayURL + "/transcribe") else {
            throw URLError(.badURL)
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: fileURL)

        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"recording.wav\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n")

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        // Clean up temp file
        try? FileManager.default.removeItem(at: fileURL)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            if let errorBody = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw NSError(domain: "TranscriptionClient", code: httpResponse.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: errorBody.detail])
            }
            throw URLError(.init(rawValue: httpResponse.statusCode))
        }

        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return decoded.text
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}

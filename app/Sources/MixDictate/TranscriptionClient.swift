import Foundation

struct TranscriptionResponse: Decodable {
    let text: String
    let raw: String?
    let language: String?
    let elapsedMs: Int?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case text, raw, language, error
        case elapsedMs = "elapsed_ms"
    }
}

struct HealthResponse: Decodable {
    let ok: Bool
    let model: String
    let hotwords: Int
    let hotwordsPath: String?

    enum CodingKeys: String, CodingKey {
        case ok, model, hotwords
        case hotwordsPath = "hotwords_path"
    }
}

enum TranscriptionError: LocalizedError {
    case serverUnreachable
    case server(String)

    var errorDescription: String? {
        switch self {
        case .serverUnreachable:
            return "连不上本地转写服务，先运行 make server"
        case .server(let message):
            return message
        }
    }
}

/// 把 WAV 发给本地服务。只走 127.0.0.1，音频不出本机。
struct TranscriptionClient {
    let config: Config

    func transcribe(wav: Data, partial: Bool = false) async throws -> String {
        let boundary = "mixdictate.\(UUID().uuidString)"

        var request = URLRequest(url: config.transcribeURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = body(wav: wav, boundary: boundary, partial: partial)

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw TranscriptionError.serverUnreachable
        }

        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        if let error = decoded.error, !error.isEmpty {
            throw TranscriptionError.server(error)
        }
        return decoded.text
    }

    private func body(wav: Data, boundary: String, partial: Bool) -> Data {
        var body = Data()

        func line(_ string: String) {
            body.append(contentsOf: Array(string.utf8))
        }

        line("--\(boundary)\r\n")
        line("Content-Disposition: form-data; name=\"audio\"; filename=\"speech.wav\"\r\n")
        line("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        line("\r\n")

        line("--\(boundary)\r\n")
        line("Content-Disposition: form-data; name=\"strip_fillers\"\r\n\r\n")
        line("\(config.stripFillers)\r\n")

        line("--\(boundary)\r\n")
        line("Content-Disposition: form-data; name=\"collapse_repeats\"\r\n\r\n")
        line("\(config.collapseRepeats)\r\n")

        line("--\(boundary)\r\n")
        line("Content-Disposition: form-data; name=\"fullwidth_punct\"\r\n\r\n")
        line("\(config.fullwidthPunctuation)\r\n")

        line("--\(boundary)\r\n")
        line("Content-Disposition: form-data; name=\"spoken_numbers\"\r\n\r\n")
        line("\(config.spokenNumbers)\r\n")

        line("--\(boundary)\r\n")
        line("Content-Disposition: form-data; name=\"spoken_symbols\"\r\n\r\n")
        line("\(config.spokenSymbols)\r\n")

        line("--\(boundary)\r\n")
        line("Content-Disposition: form-data; name=\"partial\"\r\n\r\n")
        line("\(partial)\r\n")

        line("--\(boundary)--\r\n")
        return body
    }
}

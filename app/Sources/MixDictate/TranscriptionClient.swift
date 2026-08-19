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

    /// 提前把模型热起来。失败无所谓 —— 这只是优化，不是必需步骤。
    func warmup() async {
        var request = URLRequest(url: config.warmupURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        _ = try? await URLSession.shared.data(for: request)
    }

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

        // 只要原文时，所有加工开关一次性关掉 —— 用一个地方统一决定，
        // 比在每个字段上各写一遍条件更不容易漏。
        let raw = config.rawOutput

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
        line("\(raw ? false : config.stripFillers)\r\n")

        line("--\(boundary)\r\n")
        line("Content-Disposition: form-data; name=\"collapse_repeats\"\r\n\r\n")
        line("\(raw ? false : config.collapseRepeats)\r\n")

        line("--\(boundary)\r\n")
        line("Content-Disposition: form-data; name=\"fullwidth_punct\"\r\n\r\n")
        line("\(raw ? false : config.fullwidthPunctuation)\r\n")

        line("--\(boundary)\r\n")
        line("Content-Disposition: form-data; name=\"spoken_numbers\"\r\n\r\n")
        line("\(raw ? false : config.spokenNumbers)\r\n")

        line("--\(boundary)\r\n")
        line("Content-Disposition: form-data; name=\"spoken_symbols\"\r\n\r\n")
        line("\(raw ? false : config.spokenSymbols)\r\n")

        line("--\(boundary)\r\n")
        line("Content-Disposition: form-data; name=\"merge_pause_periods\"\r\n\r\n")
        line("\(raw ? false : config.mergePausePeriods)\r\n")

        line("--\(boundary)\r\n")
        line("Content-Disposition: form-data; name=\"split_clauses\"\r\n\r\n")
        line("\(raw ? false : config.splitClauses)\r\n")

        line("--\(boundary)\r\n")
        line("Content-Disposition: form-data; name=\"partial\"\r\n\r\n")
        line("\(partial)\r\n")

        line("--\(boundary)--\r\n")
        return body
    }
}

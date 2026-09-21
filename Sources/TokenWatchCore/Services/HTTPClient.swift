import Foundation

/// Thin URLSession JSON wrapper used by every provider's usage client instead of hand-rolling
/// `URLSession` calls.
public struct HTTPClient: Sendable {
    public static let shared = HTTPClient()

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func get<T: Decodable>(_ url: URL, headers: [String: String] = [:], decode: T.Type = T.self) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return try await send(request)
    }

    public func post<T: Decodable>(_ url: URL, headers: [String: String] = [:], body: Data?, decode: T.Type = T.self) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = body
        return try await send(request)
    }

    /// Raw GET returning the response body and status code, for non-JSON or protobuf endpoints.
    public func getRaw(_ url: URL, headers: [String: String] = [:]) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (data, status)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let status: Int
        do {
            let (responseData, response) = try await session.data(for: request)
            data = responseData
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        guard (200...299).contains(status) else {
            throw ProviderError.http(status: status, message: Self.errorMessage(from: data))
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ProviderError.parse("\(error)")
        }
    }

    /// Every provider's usage API returns errors as JSON, but the shape differs (Anthropic
    /// nests under `error.message`, most OpenAI-compatible APIs match that same shape, a few
    /// return a flat `message`). Try those common shapes first so a dashboard error reads as a
    /// sentence, not a raw JSON blob; fall back to the truncated raw body for any shape none of
    /// them match, rather than swallowing the error entirely.
    static func errorMessage(from data: Data) -> String? {
        struct CommonErrorBody: Decodable {
            struct Nested: Decodable { let message: String? }
            let error: Nested?
            let message: String?
        }
        if let body = try? JSONDecoder().decode(CommonErrorBody.self, from: data),
           let message = body.error?.message ?? body.message, !message.isEmpty {
            return message
        }
        return String(data: data, encoding: .utf8).map { String($0.prefix(200)) }
    }
}

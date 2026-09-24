import Foundation
import XCTest
@testable import TokenWatchCore

/// The server's contract files (`Contracts/schema`, `Contracts/fixtures`), copied from
/// tokenwatch-cloud's `packages/contracts` build.
enum Contract {
    static func data(_ path: String) throws -> Data {
        let root = try XCTUnwrap(Bundle.module.url(forResource: "Contracts", withExtension: nil))
        return try Data(contentsOf: root.appendingPathComponent(path))
    }

    static func json(_ path: String) throws -> Any {
        try JSONSerialization.jsonObject(with: data(path))
    }

    static func schema(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(json("schema/\(name).json") as? [String: Any])
    }

    static func fixtureNames(prefix: String) throws -> [String] {
        let root = try XCTUnwrap(Bundle.module.url(forResource: "Contracts", withExtension: nil))
        return try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("fixtures").path)
            .filter { $0.hasPrefix(prefix) }
            .sorted()
    }
}

/// The subset of JSON Schema draft 2020-12 the contract's generated schemas use. Returns every
/// violation, empty when `instance` conforms.
enum JSONSchemaCheck {
    static func errors(_ instance: Any, _ schema: [String: Any], at path: String = "$") -> [String] {
        var errors: [String] = []
        if let options = schema["anyOf"] as? [[String: Any]] {
            if !options.contains(where: { self.errors(instance, $0, at: path).isEmpty }) {
                errors.append("\(path): matches no anyOf option")
            }
        }
        if let type = schema["type"] as? String, !matches(instance, type: type) {
            return errors + ["\(path): not a \(type)"]
        }
        if let constant = schema["const"], !isEqual(instance, constant) {
            errors.append("\(path): not \(constant)")
        }
        if let allowed = schema["enum"] as? [Any], !allowed.contains(where: { isEqual(instance, $0) }) {
            errors.append("\(path): \(instance) not in enum")
        }
        if let string = instance as? String {
            let length = (string as NSString).length
            if let min = schema["minLength"] as? Int, length < min { errors.append("\(path): shorter than \(min)") }
            if let max = schema["maxLength"] as? Int, length > max { errors.append("\(path): longer than \(max)") }
            if let pattern = schema["pattern"] as? String, string.range(of: pattern, options: .regularExpression) == nil {
                errors.append("\(path): \"\(string)\" doesn't match \(pattern)")
            }
        }
        if let number = instance as? NSNumber, !isBool(number) {
            if let min = schema["minimum"] as? Double, number.doubleValue < min { errors.append("\(path): below \(min)") }
            if let max = schema["maximum"] as? Double, number.doubleValue > max { errors.append("\(path): above \(max)") }
        }
        if let array = instance as? [Any] {
            if let min = schema["minItems"] as? Int, array.count < min { errors.append("\(path): fewer than \(min) items") }
            if let max = schema["maxItems"] as? Int, array.count > max { errors.append("\(path): more than \(max) items") }
            if let items = schema["items"] as? [String: Any] {
                for (index, item) in array.enumerated() { errors += self.errors(item, items, at: "\(path)[\(index)]") }
            }
        }
        if let object = instance as? [String: Any] {
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            for key in schema["required"] as? [String] ?? [] where object[key] == nil {
                errors.append("\(path): missing \(key)")
            }
            for (key, value) in object {
                if let property = properties[key] {
                    errors += self.errors(value, property, at: "\(path).\(key)")
                } else if schema["additionalProperties"] as? Bool == false {
                    errors.append("\(path): unexpected \(key)")
                }
            }
        }
        return errors
    }

    private static func isBool(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }

    private static func matches(_ instance: Any, type: String) -> Bool {
        switch type {
        case "object": return instance is [String: Any]
        case "array": return instance is [Any]
        case "string": return instance is String
        case "boolean": return (instance as? NSNumber).map(isBool) ?? false
        case "number": return (instance as? NSNumber).map { !isBool($0) } ?? false
        case "integer": return (instance as? NSNumber).map { !isBool($0) && $0.doubleValue.rounded() == $0.doubleValue } ?? false
        case "null": return instance is NSNull
        default: return true
        }
    }

    private static func isEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        (lhs as? NSObject)?.isEqual(rhs) ?? false
    }
}

/// A `URLSession` whose requests never leave the process: each is recorded and answered by
/// `reply`. Tests run serially, so one stub is live at a time.
final class StubHTTP: @unchecked Sendable {
    enum Reply {
        case status(Int, headers: [String: String] = [:], body: String = "")
        case offline
    }

    struct Request {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data?
    }

    private let lock = NSLock()
    private var recorded: [Request] = []
    private var replyHandler: (Request) -> Reply = { _ in .offline }
    let client: HTTPClient

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        client = HTTPClient(session: URLSession(configuration: configuration))
        StubURLProtocol.current = self
    }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func reply(_ handler: @escaping (Request) -> Reply) {
        lock.lock()
        replyHandler = handler
        lock.unlock()
    }

    fileprivate func handle(_ request: Request) -> Reply {
        lock.lock()
        recorded.append(request)
        let handler = replyHandler
        lock.unlock()
        return handler(request)
    }
}

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static weak var current: StubHTTP?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            var data = Data()
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            stream.close()
            body = data
        }
        let recorded = StubHTTP.Request(method: request.httpMethod ?? "GET", url: request.url!, headers: request.allHTTPHeaderFields ?? [:], body: body)
        switch Self.current?.handle(recorded) ?? .offline {
        case .offline:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case let .status(status, headers, text):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

final class MemoryTokenStore: LeaderboardTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(_ value: String? = nil) { self.value = value }

    func token() -> String? { lock.withLock { value } }
    func setToken(_ token: String) throws { lock.withLock { value = token } }
    func deleteToken() throws { lock.withLock { value = nil } }
}

/// Stands in for `ASWebAuthenticationSession`: records the URL it was asked to open and answers
/// with whatever callback `respond` builds from it.
@MainActor
final class FakeAuthenticator: LeaderboardWebAuthenticating {
    var openedURL: URL?
    var respond: (URL) throws -> URL

    init(respond: @escaping (URL) throws -> URL) {
        self.respond = respond
    }

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        openedURL = url
        return try respond(url)
    }

    func cancel() {}

    nonisolated static func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

func makeTemporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

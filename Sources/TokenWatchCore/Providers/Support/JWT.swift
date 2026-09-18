import Foundation

/// Minimal JWT payload decoding -- enough to read standard claims like `exp` without verifying
/// the signature (TokenWatch only reads tokens it did not issue, purely to check expiry).
enum JWT {
    static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        guard let data = base64URLDecode(String(parts[1])) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// `exp` claim as a `Date`, if present and well-formed.
    static func expiry(_ token: String) -> Date? {
        guard let payload = payload(token) else { return nil }
        if let exp = payload["exp"] as? Double {
            return Date(timeIntervalSince1970: exp)
        }
        if let exp = payload["exp"] as? Int {
            return Date(timeIntervalSince1970: Double(exp))
        }
        return nil
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}

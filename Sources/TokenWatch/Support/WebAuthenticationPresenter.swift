import AppKit
import AuthenticationServices
import TokenWatchCore

/// Shows tokenwat.ch's GitHub sign-in in `ASWebAuthenticationSession` and hands back its
/// `tokenwatch://auth/callback` URL. Not ephemeral: an existing GitHub session in the browser is
/// reused, so a signed-in user only confirms.
@MainActor
final class WebAuthenticationPresenter: NSObject, LeaderboardWebAuthenticating, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        cancel()
        let result = ResumeOnce()
        return try await withCheckedThrowingContinuation { continuation in
            result.continuation = continuation
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { [weak self] callbackURL, error in
                Task { @MainActor in self?.session = nil }
                if let callbackURL {
                    result.resume(.success(callbackURL))
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    result.resume(.failure(LeaderboardSignInError.cancelled))
                } else {
                    result.resume(.failure(LeaderboardSignInError.couldNotStart))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                self.session = nil
                result.resume(.failure(LeaderboardSignInError.couldNotStart))
            }
        }
    }

    /// The session's completion handler still runs (with `canceledLogin`) and clears `session`.
    func cancel() {
        session?.cancel()
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor()
        }
    }

    /// Resumes the continuation exactly once, however many ways the session reports its end.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        var continuation: CheckedContinuation<URL, Error>?

        func resume(_ result: Result<URL, Error>) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }
}

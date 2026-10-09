import AppKit
import AuthenticationServices
import TMflashCore

@MainActor
final class BrowserLogin: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func signIn(url: String) async throws -> FlasherSession {
        let attempt = try AccountLoginAttempt(url: url)
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: attempt.authorizationURL, callbackURLScheme: AccountLoginAttempt.callbackScheme) { url, _ in
                if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: EdgeError("Sign-in cancelled. No device was changed.")) }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: EdgeError("Could not open the console sign-in window"))
            }
        }
        session = nil
        return try await attempt.complete(callback: callback)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
    }
}

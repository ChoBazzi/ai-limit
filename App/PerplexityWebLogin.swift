import AppKit
import WebKit
import AILimitCore
import AILimitShared

/// Captures only the session created in this window. This is web-session authentication,
/// not an OAuth grant; the caller must verify quota access before saving the credential.
@MainActor
final class PerplexityWebLogin: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private static let signInURL = URL(string: "https://www.perplexity.ai/auth/signin")!
    // Perplexity /api/auth/providers and Google's / Apple's OIDC discovery identify
    // these SSO providers. Unknown enterprise IdPs deliberately fail closed.
    private static let loginHosts: Set<String> = [
        "www.perplexity.ai", "perplexity.ai", "accounts.google.com", "appleid.apple.com"
    ]
    private static let cookieFamilies = [
        "__Secure-authjs.session-token", "authjs.session-token",
        "__Secure-next-auth.session-token", "next-auth.session-token"
    ]

    private var window: NSWindow?
    private var webView: WKWebView?
    private var statusLabel: NSTextField?
    private var store: WKWebsiteDataStore?
    private var continuation: CheckedContinuation<DirectCredential, any Error>?
    private var polling: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var attempt: UUID?
    private var previousCandidate: String?

    func signIn() async throws -> DirectCredential {
        guard attempt == nil else {
            throw UsageError.configuration("Perplexity 로그인이 이미 진행 중입니다.")
        }
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                self.attempt = id
                self.openWindow()
                self.polling = Task { [weak self] in
                    do {
                        while !Task.isCancelled {
                            try await Task.sleep(for: .seconds(1))
                            guard let self, self.attempt == id else { return }
                            try await self.inspectSession(id: id)
                        }
                    } catch {
                        self?.finish(.failure(error), id: id)
                    }
                }
                self.deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(600)) }
                    catch { return }
                    self?.finish(.failure(UsageError.unavailable("Perplexity 로그인 제한 시간(10분)이 지났습니다. 다시 연결하세요.")), id: id)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.failure(CancellationError()), id: id)
            }
        }
    }

    func cancel() {
        guard let attempt else { return }
        finish(.failure(CancellationError()), id: attempt)
    }

    @objc private func cancelPressed(_ sender: NSButton) { cancel() }

    private func openWindow() {
        let store = WKWebsiteDataStore.nonPersistent()
        self.store = store
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // No injected scripts, script-message handlers, native bridge or external stores.
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.isInspectable = false
        self.webView = webView

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 760),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "AI Limit · Perplexity 로그인"
        window.minSize = NSSize(width: 620, height: 580)
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        let caveat = NSTextField(wrappingLabelWithString:
            "이 임시 창에서 직접 로그인하세요. 다른 앱·브라우저의 계정은 읽지 않습니다. 세션은 사용량 조회보다 넓은 계정 권한을 가질 수 있습니다. Google·Apple 또는 기업 SSO가 내장 브라우저를 차단할 수 있습니다. 이 경우 지원되는 이메일 로그인을 사용하거나 취소하세요. 10분 후 자동 종료됩니다.")
        caveat.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        caveat.textColor = .secondaryLabelColor
        let status = NSTextField(labelWithString: "www.perplexity.ai · 로그인 대기 중")
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.lineBreakMode = .byTruncatingTail
        self.statusLabel = status
        let cancel = NSButton(title: "로그인 취소", target: self, action: #selector(cancelPressed(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [status, cancel])
        footer.orientation = .horizontal
        footer.distribution = .fill
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let content = NSView()
        window.contentView = content
        for view in [caveat, webView, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            caveat.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            caveat.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            caveat.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            webView.topAnchor.constraint(equalTo: caveat.bottomAnchor, constant: 12),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        webView.load(URLRequest(url: Self.signInURL))
    }

    private struct SessionCandidate {
        let header: String
        let expiresAt: Date?
    }

    private static func candidate(from cookies: [HTTPCookie], now: Date) throws -> SessionCandidate? {
        let scoped = cookies.filter {
            ["perplexity.ai", ".perplexity.ai", "www.perplexity.ai", ".www.perplexity.ai"].contains($0.domain.lowercased())
                && $0.path == "/" && $0.isSecure && $0.isHTTPOnly
                && ($0.expiresDate.map { $0 > now } ?? true)
        }
        for family in cookieFamilies {
            let direct = scoped.filter { $0.name == family }
            let chunks = scoped.compactMap { cookie -> (Int, HTTPCookie)? in
                guard cookie.name.hasPrefix(family + ".") else { return nil }
                let suffix = String(cookie.name.dropFirst(family.count + 1))
                guard let index = Int(suffix), index >= 0, String(index) == suffix else { return nil }
                return (index, cookie)
            }.sorted { $0.0 < $1.0 }
            let selected: [HTTPCookie]
            if !direct.isEmpty {
                // Do not choose arbitrarily between host/domain cookies with the same name.
                guard direct.count == 1 else { throw UsageError.authentication }
                selected = direct
            } else {
                guard !chunks.isEmpty,
                      chunks.enumerated().allSatisfy({ $0.offset == $0.element.0 }) else { continue }
                selected = chunks.map { $0.1 }
                guard Set(selected.map(\.domain)).count == 1 else { throw UsageError.authentication }
            }
            guard selected.allSatisfy({ cookie in
                !cookie.value.isEmpty && cookie.value.utf8.allSatisfy {
                    (0x21...0x7E).contains($0) && ![0x22, 0x2C, 0x3B, 0x5C].contains($0)
                }
            }) else { throw UsageError.authentication }
            let header = selected.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            guard header.utf8.count <= 32 * 1024 else { throw UsageError.authentication }
            return SessionCandidate(header: try Credentials.validate(header, for: .perplexity),
                                    expiresAt: selected.compactMap(\.expiresDate).min())
        }
        return nil
    }

    private func inspectSession(id: UUID) async throws {
        guard attempt == id, let store else { return }
        let cookies = await store.httpCookieStore.allCookies()
        guard attempt == id, !Task.isCancelled else { return }
        guard let candidate = try Self.candidate(from: cookies, now: Date()) else {
            previousCandidate = nil
            return
        }
        // Cookie chunks may arrive in separate writes; wait for two equal observations.
        guard previousCandidate == candidate.header else {
            previousCandidate = candidate.header
            return
        }
        statusLabel?.stringValue = "Perplexity 세션 확인 중 · 사용량 확인 후 연결됩니다"
        let response = try await SecureHTTPTransport().send(HTTPRequest(
            "https://www.perplexity.ai/api/auth/session",
            headers: ["Cookie": candidate.header, "Accept": "application/json",
                      "Origin": "https://www.perplexity.ai", "Referer": "https://www.perplexity.ai/auth/signin"],
            timeout: 20))
        guard attempt == id, !Task.isCancelled else { return }
        let data = try response.checked(now: Date())
        struct Session: Decodable {
            struct User: Decodable { let email: String? }
            let user: User?
            let expires: String?
        }
        guard let session = try? JSONDecoder().decode(Session.self, from: data),
              let email = session.user?.email, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UsageError.authentication
        }
        // Session endpoint expiry can be earlier than the cookie expiry. Never invent
        // a lifetime for session-only cookies or use an unverified JWT expiration.
        var expiration = candidate.expiresAt
        if let text = session.expires {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var parsed = formatter.date(from: text)
            if parsed == nil {
                formatter.formatOptions = [.withInternetDateTime]
                parsed = formatter.date(from: text)
            }
            guard let parsed else { throw UsageError.authentication }
            expiration = expiration.map { min($0, parsed) } ?? parsed
        }
        guard expiration.map({ $0 > Date() }) ?? true else { throw UsageError.authentication }
        // A sign-out or account switch during HTTP validation invalidates this attempt.
        let latestCookies = await store.httpCookieStore.allCookies()
        guard attempt == id, !Task.isCancelled else { return }
        guard let latest = try Self.candidate(from: latestCookies, now: Date()),
              latest.header == candidate.header else {
            previousCandidate = nil
            return
        }
        if let latestExpiration = latest.expiresAt {
            expiration = expiration.map { min($0, latestExpiration) } ?? latestExpiration
        }
        guard expiration.map({ $0 > Date() }) ?? true else { throw UsageError.authentication }
        finish(.success(DirectCredential(provider: .perplexity, accessToken: candidate.header,
                                         expiresAt: expiration)), id: id)
    }

    private func finish(_ result: Result<DirectCredential, any Error>, id: UUID) {
        guard attempt == id, let continuation else { return }
        attempt = nil
        self.continuation = nil
        polling?.cancel()
        polling = nil
        deadline?.cancel()
        deadline = nil
        previousCandidate = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        window?.delegate = nil
        window?.close()
        window = nil
        statusLabel = nil
        // Detach synchronously so a slow WebKit completion cannot hang cancellation.
        // This only touches this attempt's nonpersistent store, never the default store.
        let oldStore = store
        store = nil
        oldStore?.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                             modifiedSince: .distantPast, completionHandler: {})
        continuation.resume(with: result)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow, closed === window else { return }
        cancel()
    }

    private static func permitted(_ url: URL?, isMainFrame: Bool = true) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        // Turnstile documents this exact frame origin; it never gets a top-level
        // window, popup permission, or access to the native credential boundary.
        return loginHosts.contains(host) || (!isMainFrame && host == "challenges.cloudflare.com")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard webView === self.webView else { decisionHandler(.cancel); return }
        guard attempt != nil,
              Self.permitted(navigationAction.request.url, isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true),
              !navigationAction.shouldPerformDownload else {
            decisionHandler(.cancel)
            if navigationAction.targetFrame?.isMainFrame != false, let attempt {
                finish(.failure(UsageError.unavailable("허용되지 않는 로그인 이동 또는 다운로드가 차단되었습니다. 지원되는 이메일 로그인을 사용하세요.")), id: attempt)
            }
            return
        }
        if navigationAction.targetFrame == nil {
            // A user-initiated trusted login popup stays in this same ephemeral window.
            let origin = navigationAction.sourceFrame.securityOrigin
            guard origin.protocol == "https", Self.loginHosts.contains(origin.host.lowercased()),
                  origin.port == 0 || origin.port == 443 else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.cancel)
            webView.load(navigationAction.request)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        guard webView === self.webView else { decisionHandler(.cancel); return }
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased()
        guard Self.permitted(navigationResponse.response.url, isMainFrame: navigationResponse.isForMainFrame),
              navigationResponse.canShowMIMEType,
              disposition?.contains("attachment") != true else {
            decisionHandler(.cancel)
            if navigationResponse.isForMainFrame, let attempt {
                finish(.failure(UsageError.unavailable("로그인 응답 또는 다운로드가 차단되었습니다.")), id: attempt)
            }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Navigation policy handles the allowlisted target in the existing view.
        nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        statusLabel?.stringValue = "\(webView.url?.host ?? "Perplexity") · 로그인 진행 중"
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        guard webView === self.webView else { return }
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        guard webView === self.webView else { return }
        navigationFailed(error)
    }

    private func navigationFailed(_ error: any Error) {
        let error = error as NSError
        // Cancellation is normal when redirecting a permitted popup into this view.
        guard !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled), let attempt else { return }
        finish(.failure(UsageError.unavailable("Perplexity 로그인 페이지를 열 수 없습니다. 네트워크 또는 내장 브라우저 제한을 확인하세요.")), id: attempt)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView, let attempt else { return }
        finish(.failure(UsageError.unavailable("로그인 웹 프로세스가 종료되었습니다. 다시 연결하세요.")), id: attempt)
    }
}

import SwiftUI
import UIKit
import WebKit

final class BrowserModel: NSObject, ObservableObject {
    let site: Site
    let webView: WKWebView
    let container = UIView()

    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress = 0.0
    @Published var toast: String?
    @Published var gate: Gate = .none
    @Published var gateInfo = ""

    private var popup: WKWebView?
    private var popupHolder: UIView?
    private var toastWork: DispatchWorkItem?
    private var lastAdded = Date.distantPast
    private var observations: [NSKeyValueObservation] = []

    init(site: Site, autoload: Bool = true) {
        self.site = site

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.applicationNameForUserAgent = "Version/18.0 Mobile/15E148 Safari/604.1"
        let ucc = WKUserContentController()
        config.userContentController = ucc
        webView = WKWebView(frame: .zero, configuration: config)

        super.init()

        let router = MessageRouter(owner: self)
        ucc.addScriptMessageHandler(router, contentWorld: .defaultClient, name: "df")
        ucc.add(router, contentWorld: .page, name: "dfhook")
        ucc.addUserScript(WKUserScript(source: Scripts.hook, injectionTime: .atDocumentStart,
                                       forMainFrameOnly: true, in: .page))
        ucc.addUserScript(WKUserScript(source: Scripts.autofill, injectionTime: .atDocumentEnd,
                                       forMainFrameOnly: false, in: .defaultClient))
        ucc.addUserScript(WKUserScript(source: Scripts.gate, injectionTime: .atDocumentEnd,
                                       forMainFrameOnly: true, in: .defaultClient))

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        if #available(iOS 16.4, *) { webView.isInspectable = true }

        container.backgroundColor = .systemBackground
        pin(webView, in: container)

        observations = [
            webView.observe(\.canGoBack, options: [.new]) { [weak self] w, _ in self?.canGoBack = w.canGoBack },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] w, _ in self?.canGoForward = w.canGoForward },
            webView.observe(\.isLoading, options: [.new]) { [weak self] w, _ in self?.isLoading = w.isLoading },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in self?.progress = w.estimatedProgress },
        ]

        // 저장해 둔 세션 쿠키를 먼저 되살리고, 마지막 페이지(대기열 포함)에서 다시 시작
        guard autoload else { return }
        CookieKeeper.restore { [weak self] in
            guard let self else { return }
            if SettingsStore.shared.resumeLastPage, let last = LastPage.load(site: site) {
                self.webView.load(URLRequest(url: last))
            } else {
                self.goHome()
            }
        }
    }

    // MARK: actions

    func goHome() { webView.load(URLRequest(url: SettingsStore.shared.home(for: site))) }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }

    func openCart() {
        let base = webView.url ?? SettingsStore.shared.home(for: site)
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
        c.path = "/cart"; c.query = nil; c.fragment = nil
        if let u = c.url { webView.load(URLRequest(url: u)) }
    }

    /// 대기열 중에 페이지를 떠나는 동작은 한 번 확인받는다 (순번 보호)
    func guarded(_ what: String, _ action: @escaping () -> Void) {
        guard gate == .queue, let vc = Self.topViewController() else { action(); return }
        let a = UIAlertController(title: "대기열에서 나갈까요?",
                                  message: "\(what)하면 대기 순번을 잃을 수 있어요.",
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "계속 기다리기", style: .cancel))
        a.addAction(UIAlertAction(title: what, style: .destructive) { _ in action() })
        vc.present(a, animated: true)
    }

    func refill() {
        webView.evaluateJavaScript("window.__dfRun && window.__dfRun(); 0", in: nil, in: .defaultClient) { _ in }
        showToast("다시 채우는 중")
    }

    func showToast(_ text: String, seconds: Double = 1.8) {
        toastWork?.cancel()
        withAnimation { toast = text }
        let work = DispatchWorkItem { [weak self] in withAnimation { self?.toast = nil } }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// 대기열·캡차 상태 변화
    func handleGate(_ new: Gate, info: String = "") {
        gateInfo = new == .queue ? info : ""
        let old = gate
        guard new != old else { return }
        gate = new
        webView.allowsBackForwardNavigationGestures = new != .queue
        GateCenter.set(site, gate: new)
        switch (old, new) {
        case (_, .queue):
            Notifier.shared.notify("\(site.title) 대기열", "대기열에 들어갔어요. 앱을 켜 둔 채로 기다려 주세요.", haptic: .warning, site: site)
        case (_, .captcha):
            Notifier.shared.notify("\(site.title) 캡차", "캡차가 떴어요. 직접 풀어 주세요.", haptic: .error, site: site)
            NotificationCenter.default.post(name: .dropFillFocus, object: site.rawValue)
        case (.queue, .none):
            Notifier.shared.notify("\(site.title) 대기열 통과", "입장했어요. 이어서 진행하세요.", haptic: .success, site: site)
            NotificationCenter.default.post(name: .dropFillFocus, object: site.rawValue)
            showToast("대기열 통과! 이어서 진행하세요", seconds: 3)
        case (.captcha, .none):
            showToast("확인 통과")
        default:
            break
        }
    }

    /// 장바구니 담기 성공 → 체크아웃으로 이동
    func handleAdded(checkoutURL: String?) {
        let s = SettingsStore.shared
        guard gate == .none else { return }   // 대기열·캡차 중엔 사이트 흐름을 건드리지 않음
        guard s.autoCheckoutOn else { showToast("장바구니에 담김"); return }
        guard Date().timeIntervalSince(lastAdded) > 3 else { return }
        if let cur = webView.url, cur.path.lowercased().contains("checkout") { return }
        lastAdded = Date()

        var target: URL?
        if let str = checkoutURL, let u = URL(string: str, relativeTo: webView.url)?.absoluteURL,
           let h = u.host, s.isShopHost(h) {
            target = u
        }
        if target == nil, let cur = webView.url, var c = URLComponents(url: cur, resolvingAgainstBaseURL: false) {
            c.path = "/cart"; c.query = nil; c.fragment = nil   // 장바구니 페이지에서 체크아웃 버튼 자동 클릭
            target = c.url
        }
        guard let t = target else { return }
        showToast("담김 → 체크아웃으로 이동")
        webView.load(URLRequest(url: t))
    }

    // MARK: popup (카드사·PG 창)

    fileprivate func openPopup(with configuration: WKWebViewConfiguration) -> WKWebView {
        closePopup()
        let holder = UIView()
        holder.backgroundColor = .systemBackground
        let bar = UIView()
        bar.backgroundColor = .secondarySystemBackground
        let close = UIButton(type: .system)
        close.setTitle("닫기", for: .normal)
        close.titleLabel?.font = .boldSystemFont(ofSize: 16)
        close.addAction(UIAction { [weak self] _ in self?.closePopup() }, for: .touchUpInside)

        let pop = WKWebView(frame: .zero, configuration: configuration)
        pop.navigationDelegate = self
        pop.uiDelegate = self

        [bar, close, pop].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        holder.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(holder)
        holder.addSubview(bar)
        bar.addSubview(close)
        holder.addSubview(pop)
        NSLayoutConstraint.activate([
            holder.topAnchor.constraint(equalTo: container.topAnchor),
            holder.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            holder.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            holder.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.topAnchor.constraint(equalTo: holder.topAnchor),
            bar.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 44),
            close.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
            close.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            pop.topAnchor.constraint(equalTo: bar.bottomAnchor),
            pop.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            pop.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            pop.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        ])
        popup = pop
        popupHolder = holder
        return pop
    }

    func closePopup() {
        popup?.stopLoading()
        popupHolder?.removeFromSuperview()
        popup = nil
        popupHolder = nil
    }

    private func pin(_ v: UIView, in parent: UIView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: parent.topAnchor),
            v.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        ])
    }

    fileprivate static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        var vc = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }
}

// MARK: - Navigation / UI delegate

extension BrowserModel: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        // 쇼핑몰·대기열 페이지만 '마지막 페이지'로 기억 (결제사·외부 페이지로 재시작하지 않게)
        if let h = webView.url?.host,
           SettingsStore.shared.isShopHost(h) || h.hasSuffix("queue-it.net") || h.hasSuffix("queue-it.com") {
            LastPage.save(webView.url, site: site)
        }
        CookieKeeper.save()
    }

    // 메모리 부족 등으로 웹 프로세스가 죽으면 흰 화면이 됨 → 같은 주소로 복구 (쿠키가 있어 순번 유지)
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        showToast("페이지가 멈춰서 다시 불러와요")
        if let url = webView.url ?? LastPage.load(site: site) {
            webView.load(URLRequest(url: url))
        } else {
            webView.reload()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        reportFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportFailure(error)
    }

    private func reportFailure(_ error: Error) {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain" && (e.code == 102 || e.code == 204) { return } // 다운로드·외부앱 전환
        showToast("연결 실패 · ↻ 눌러 다시 시도", seconds: 3)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow); return
        }
        if ["http", "https", "about", "blob", "data", "javascript"].contains(scheme) {
            decisionHandler(.allow); return
        }
        // 카드사 앱카드·ISP 등 외부 앱 호출
        decisionHandler(.cancel)
        UIApplication.shared.open(url, options: [:]) { [weak self] ok in
            if !ok { self?.showToast("앱을 열 수 없어요 (\(scheme))") }
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        openPopup(with: configuration)
    }

    func webViewDidClose(_ webView: WKWebView) {
        if webView === popup { closePopup() }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let vc = Self.topViewController() else { completionHandler(); return }
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "확인", style: .default) { _ in completionHandler() })
        vc.present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let vc = Self.topViewController() else { completionHandler(false); return }
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "확인", style: .default) { _ in completionHandler(true) })
        vc.present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        guard let vc = Self.topViewController() else { completionHandler(nil); return }
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "확인", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
        vc.present(a, animated: true)
    }
}

// MARK: - Script messages

final class MessageRouter: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {
    weak var owner: BrowserModel?
    init(owner: BrowserModel) { self.owner = owner }

    /// page world (hook.js): 장바구니 담기 감지
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              body["type"] as? String == "added",
              SettingsStore.shared.isShopHost(message.frameInfo.securityOrigin.host) else { return }
        owner?.handleAdded(checkoutURL: body["checkoutUrl"] as? String)
    }

    /// isolated world (autofill.js): 설정 요청·결과 알림
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        let body = message.body as? [String: Any] ?? [:]
        let host = message.frameInfo.securityOrigin.host
        switch body["type"] as? String ?? "" {
        case "config":
            replyHandler(SettingsStore.shared.config(forHost: host, site: owner?.site ?? .supreme), nil)
            return
        case "filled":
            let n = body["count"] as? Int ?? 0
            let card = body["card"] as? Bool ?? false
            owner?.showToast(card ? "카드 정보 입력됨" : "자동입력 \(n)칸")
        case "gate":
            if message.frameInfo.isMainFrame, let k = body["kind"] as? String, let g = Gate(rawValue: k) {
                owner?.handleGate(g, info: body["info"] as? String ?? "")
            }
        case "ready":
            owner?.showToast("준비 완료 · 빨간 테두리 결제 버튼만 누르세요", seconds: 3)
        case "log":
            if let m = body["msg"] as? String { owner?.showToast(m) }
        default:
            break
        }
        replyHandler(nil, nil)
    }
}

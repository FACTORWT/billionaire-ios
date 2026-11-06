import UIKit
import WebKit
import StoreKit
import SafariServices

final class WebViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView!
    private let startURL = URL(string: "https://billionseb.com/")!

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let ucc = WKUserContentController()
        for name in ["share", "review", "purchase", "restore"] {
            ucc.add(self, name: name)
        }
        config.userContentController = ucc

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        var req = URLRequest(url: startURL)
        req.cachePolicy = .returnCacheDataElseLoad
        webView.load(req)
        registerForPushIfNeeded()
    }

    func evaluateJS(_ js: String) {
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: JS bridge
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        switch message.name {
        case "share":
            let text = (message.body as? [String: Any])?["text"] as? String ?? "Billionaire: Empire Builder"
            let url = URL(string: (message.body as? [String: Any])?["url"] as? String ?? "https://billionseb.com/")!
            let av = UIActivityViewController(activityItems: [text, url], applicationActivities: nil)
            present(av, animated: true)
        case "review":
            requestNativeReview()
        case "purchase":
            if let pid = (message.body as? [String: Any])?["productId"] as? String {
                Task { await StoreManager.shared.purchase(productId: pid) }
            }
        case "restore":
            Task { await StoreManager.shared.restore() }
        default: break
        }
    }

    // MARK: ABRE ENLACES EXTERNOS EN SAFARI
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
        if url.scheme == "mailto" || url.scheme == "tel" {
            UIApplication.shared.open(url); return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    private func requestNativeReview() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        if #available(iOS 16.0, *) {
            SKStoreReviewController.requestReview(in: scene)
        } else {
            SKStoreReviewController.requestReview()
        }
    }

    private func registerForPushIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
    }
}

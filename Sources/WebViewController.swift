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
        for name in ["share", "review", "purchase", "restore", "settings"] {
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
        setUpGearButton()
        registerForPushIfNeeded()
    }

    private lazy var gearButton: UIButton = {
        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.setImage(UIImage(systemName: "gearshape.fill"), for: .normal)
        b.tintColor = UIColor(white: 1.0, alpha: 0.55)
        b.backgroundColor = UIColor(white: 0.0, alpha: 0.25)
        b.layer.cornerRadius = 17
        b.addTarget(self, action: #selector(gearTapped), for: .touchUpInside)
        return b
    }()

    private func setUpGearButton() {
        view.addSubview(gearButton)
        NSLayoutConstraint.activate([
            gearButton.widthAnchor.constraint(equalToConstant: 34),
            gearButton.heightAnchor.constraint(equalToConstant: 34),
            gearButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            gearButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6)
        ])
    }

    @objc private func gearTapped() {
        showSettings()
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
        case "settings":
            DispatchQueue.main.async { self.showSettings() }
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
        if isExternalCheckout(url) {
            showNativePurchasePrompt()
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    private let externalCheckoutHosts = [
        "checkout.stripe.com", "buy.stripe.com", "billing.stripe.com",
        "checkout.mercadopago.com", "www.mercadopago.com", "mercadopago.com",
        "www.paypal.com", "www.paypal.me", "paypal.me"
    ]

    private func isExternalCheckout(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return externalCheckoutHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) })
    }

    private func showNativePurchasePrompt() {
        let alert = UIAlertController(
            title: "Magnate Pro",
            message: "La suscripción se compra dentro de la app con tu cuenta de App Store.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Comprar", style: .default, handler: { _ in
            self.evaluateJS("window.dispatchEvent(new CustomEvent('native-open-paywall'))")
        }))
        alert.addAction(UIAlertAction(title: "Ahora no", style: .cancel))
        present(alert, animated: true)
    }

    private func showSettings() {
        let sheet = UIAlertController(title: "Ajustes", message: nil, preferredStyle: .actionSheet)

        let reminderTitle = NotificationScheduler.isEnabled()
            ? "Recordatorio diario: activo a las \(NotificationScheduler.currentHour()):00"
            : "Recordatorio diario: desactivado"
        sheet.addAction(UIAlertAction(title: reminderTitle, style: .default, handler: { _ in
            NotificationScheduler.setEnabled(!NotificationScheduler.isEnabled())
        }))

        sheet.addAction(UIAlertAction(title: "Cambiar hora del recordatorio", style: .default, handler: { _ in
            self.chooseReminderHour()
        }))

        sheet.addAction(UIAlertAction(title: "Política de privacidad", style: .default, handler: { _ in
            if let u = URL(string: "https://billionseb.com/PrivacyPolicy") {
                self.present(SFSafariViewController(url: u), animated: true)
            }
        }))

        sheet.addAction(UIAlertAction(title: "Eliminar mi cuenta", style: .destructive, handler: { _ in
            self.confirmAccountDeletion()
        }))

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        sheet.addAction(UIAlertAction(title: "Versión \(version)", style: .default))

        sheet.addAction(UIAlertAction(title: "Cerrar", style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
        present(sheet, animated: true)
    }

    private func chooseReminderHour() {
        let alert = UIAlertController(title: "Hora del recordatorio", message: nil, preferredStyle: .actionSheet)
        for h in [8, 12, 18, 19, 20, 21] {
            alert.addAction(UIAlertAction(title: "\(h):00", style: .default, handler: { _ in
                NotificationScheduler.setHour(h)
                NotificationScheduler.setEnabled(true)
            }))
        }
        alert.addAction(UIAlertAction(title: "Cancelar", style: .cancel))
        if let pop = alert.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
        present(alert, animated: true)
    }

    private func confirmAccountDeletion() {
        let alert = UIAlertController(
            title: "¿Eliminar tu cuenta?",
            message: "Se borran tu progreso, tu imperio y tu suscripción no se renueva. Esta acción no se puede deshacer.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Eliminar cuenta", style: .destructive, handler: { _ in
            self.performAccountDeletion()
        }))
        alert.addAction(UIAlertAction(title: "Cancelar", style: .cancel))
        present(alert, animated: true)
    }

    private func performAccountDeletion() {
        webView.evaluateJavaScript("typeof window.__deleteAccount === 'function'") { result, _ in
            let exists = (result as? Bool) ?? false
            DispatchQueue.main.async {
                if exists {
                    self.webView.evaluateJavaScript("window.__deleteAccount()", completionHandler: nil)
                } else {
                    let alert = UIAlertController(
                        title: "Solicitud de borrado",
                        message: "Escríbenos a fmaldonado@aeternumtech.com desde el correo de tu cuenta y borramos tus datos en menos de 7 días.",
                        preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "Abrir correo", style: .default, handler: { _ in
                        if let u = URL(string: "mailto:fmaldonado@aeternumtech.com?subject=Eliminar%20mi%20cuenta%20Billionaire") {
                            UIApplication.shared.open(u)
                        }
                    }))
                    alert.addAction(UIAlertAction(title: "Cerrar", style: .cancel))
                    self.present(alert, animated: true)
                }
            }
        }
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
        NotificationScheduler.requestPermissionIfNeeded()
    }
}

import Foundation
import StoreKit

/// Compra de Magnate Pro con StoreKit 2. Los productos se definen en App Store Connect.
final class StoreManager {
    static let shared = StoreManager()
    static let monthlyProductId = "com.franciscomaldonado.billionaire.magnate_pro_monthly"

    private var updatesTask: Task<Void, Never>?

    private init() {
        updatesTask = Task.detached { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result {
                    await t.finish()
                    self?.notifyWeb(active: true)
                }
            }
        }
    }

    func purchase(productId: String) async {
        do {
            let products = try await Product.products(for: [productId])
            guard let product = products.first else { notifyWeb(error: "product_not_found"); return }
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    notifyWeb(active: true)
                } else {
                    notifyWeb(error: "unverified")
                }
            case .userCancelled: notifyWeb(error: "cancelled")
            case .pending: notifyWeb(error: "pending")
            @unknown default: notifyWeb(error: "unknown")
            }
        } catch {
            notifyWeb(error: error.localizedDescription)
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
            let active = await isProActive()
            notifyWeb(active: active)
        } catch {
            notifyWeb(error: error.localizedDescription)
        }
    }

    func isProActive() async -> Bool {
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == StoreManager.monthlyProductId, t.revocationDate == nil {
                return true
            }
        }
        return false
    }

    private func notifyWeb(active: Bool? = nil, error: String? = nil) {
        var payload: [String: Any] = [:]
        if let active = active { payload["active"] = active }
        if let error = error { payload["error"] = error }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            let js = "window.dispatchEvent(new CustomEvent('nativePurchase',{detail:\(json)}));"
            if let vc = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first as? WebViewController {
                vc.evaluateJS(js)
            }
        }
    }
}

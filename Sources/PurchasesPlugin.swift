//
//  PurchasesPlugin.swift
//  Billionaire (com.franciscomaldonado.billionaire)
//
//  StoreKit 2 bridge for the Billionaire iOS wrapper.
//
//  This repository is a native UIKit + WKWebView wrapper generated with XcodeGen
//  from Sources/ (it is NOT a Capacitor project), so this file is the Capacitor-free
//  port of ios-storekit/ios/App/App/PurchasesPlugin.swift: same contract, same
//  payloads, no `import Capacitor`, no CAPPlugin.
//
//  The web app that runs inside the WKWebView (https://billionseb.com) talks to:
//
//      window.webkit.messageHandlers.purchases.postMessage({ action, requestId, productId })
//
//  and expects a reply keyed by requestId, never a fire-and-forget. Three delivery
//  paths are supported, in this order, so both the current production bundle and the
//  new js/purchases-ios.js client work:
//
//    1. window.__billionairePurchases.receive(payload)      <- js/purchases-ios.js (contract 1.0)
//    2. window.__billionairePurchaseCallback(requestId, p)  <- live billionseb.com bundle today
//    3. CustomEvent("billionaire:purchases", { detail: p }) <- fallback
//
//  IMPORTANT: this plugin never grants Pro. It returns the signed JWS and the
//  transaction identifiers; the entitlement is written by the backend after it
//  validates the transaction with the App Store Server API.
//
//  Deployment target: iOS 15.0+ (StoreKit 2 requirement).
//

import Foundation
import StoreKit
import UIKit
import WebKit

final class PurchasesPlugin: NSObject, WKScriptMessageHandler {

    // MARK: - Contract constants (must match js/purchases-ios.js)

    static let contractVersion = "1.0"
    static let channelName = "purchases"
    static let productID = "com.franciscomaldonado.billionaire.magnate_pro_monthly"
    static let bareProductID = "magnate_pro_monthly"
    static let bundleID = "com.franciscomaldonado.billionaire"

    // MARK: - State

    private weak var webView: WKWebView?
    private let stateQueue = DispatchQueue(label: "com.franciscomaldonado.billionaire.purchases.state")
    private var transactionCache: [UInt64: VerificationResult<Transaction>] = [:]
    private var outbox: [[String: Any]] = []
    private var updatesTask: Task<Void, Never>?
    private var foregroundObserver: NSObjectProtocol?
    private let maxOutbox = 50

    // The current web client has no `finish` step, so a verified purchase would stay
    // in StoreKit's queue forever and be redelivered on every launch. The entitlement
    // is granted by the backend, and `restore` / `currentEntitlements` recover it, so
    // the transaction is finished right after it is handed to JavaScript.
    // Clients that do call action:"finish" get an idempotent success.
    private let finishAfterDeliver = true

    // MARK: - Lifecycle

    /// Called once the WKWebView exists. Starts the Transaction.updates listener.
    func attach(webView: WKWebView) {
        self.webView = webView
        startTransactionUpdatesListener()
        if foregroundObserver == nil {
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.flushOutbox()
            }
        }
    }

    deinit {
        updatesTask?.cancel()
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        let name = message.name
        guard name == Self.channelName || name == "purchase" || name == "restore" else { return }

        guard let body = message.body as? [String: Any] else {
            emit(failure("bad_request", "Mensaje nativo inválido."), requestId: nil)
            return
        }

        // The live bundle always sends `action`; fall back to the channel alias so a
        // bare postMessage({}) on "restore" still does the right thing.
        var action = (body["action"] as? String) ?? ""
        if action.isEmpty {
            if name == "restore" { action = "restore" }
            else if name == "purchase" { action = "purchase" }
        }
        let requestId = body["requestId"] as? String

        Task { [weak self] in
            guard let self = self else { return }
            let payload = await self.dispatch(action: action, body: body)
            self.emit(payload, requestId: requestId)
        }
    }

    // MARK: - Dispatch

    private func dispatch(action: String, body: [String: Any]) async -> [String: Any] {
        switch action {
        case "ready":
            flushOutbox()
            return ["status": "ready", "contractVersion": Self.contractVersion]
        case "purchase":
            return await handlePurchase(body: body)
        case "restore":
            return await handleRestore(body: body)
        case "currentEntitlements":
            return await handleCurrentEntitlements(body: body)
        case "products":
            return await handleProducts(body: body)
        case "finish":
            return await handleFinish(body: body)
        default:
            return failure("unknown_action", "Acción no soportada: \(action.isEmpty ? "(vacía)" : action)")
        }
    }

    // MARK: - purchase

    private func handlePurchase(body: [String: Any]) async -> [String: Any] {
        let requested = (body["productId"] as? String) ?? Self.productID

        guard let productID = Self.normalizeProductID(requested) else {
            return failure(
                "invalid_product_id",
                "Producto no válido: \(requested). Esperado \(Self.productID).",
                extra: ["productId": requested]
            )
        }

        // Already entitled? Return the existing transaction instead of charging again.
        if let existing = await firstActiveEntitlement(productID: productID) {
            if case .verified(let transaction) = existing {
                return purchasePayload(
                    verification: existing,
                    status: "already_subscribed",
                    action: "purchase",
                    source: "currentEntitlements",
                    transaction: transaction
                )
            }
        }

        let products: [Product]
        do {
            products = try await Product.products(for: [productID])
        } catch {
            let mapped = Self.mapStoreKitError(error)
            return failure(mapped.0, mapped.1, extra: ["productId": productID])
        }

        guard let product = products.first else {
            return failure(
                "product_not_found",
                "StoreKit no encontró \(productID). Revisa que el producto esté creado, aprobado y disponible en el territorio de la cuenta de Apple ID.",
                extra: ["productId": productID]
            )
        }

        var options: Set<Product.PurchaseOption> = []
        if let tokenString = body["appAccountToken"] as? String,
           let token = UUID(uuidString: tokenString) {
            options.insert(.appAccountToken(token))
        }

        do {
            let result = try await product.purchase(options: options)

            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    cache(verification)
                    if finishAfterDeliver {
                        await transaction.finish()
                    }
                    return purchasePayload(
                        verification: verification,
                        status: "success",
                        action: "purchase",
                        source: "purchase",
                        transaction: transaction
                    )
                case .unverified(let transaction, let error):
                    return failure(
                        "unverified_transaction",
                        "Apple no pudo verificar la transacción: \(String(describing: error))",
                        extra: [
                            "productId": transaction.productID,
                            "transactionId": String(transaction.id),
                            "success": false
                        ]
                    )
                }
            case .userCancelled:
                return [
                    "status": "cancelled",
                    "code": "user_cancelled",
                    "success": false,
                    "error": "cancelled",
                    "message": "Compra cancelada."
                ]
            case .pending:
                return [
                    "status": "pending",
                    "code": "payment_pending",
                    "success": false,
                    "error": "pending",
                    "message": "El pago está pendiente de aprobación (Ask to Buy o verificación del banco)."
                ]
            @unknown default:
                return failure("unknown_purchase_result", "Resultado de compra no reconocido.")
            }
        } catch {
            let mapped = Self.mapStoreKitError(error)
            return failure(mapped.0, mapped.1, extra: ["productId": productID])
        }
    }

    // MARK: - restore

    private func handleRestore(body: [String: Any]) async -> [String: Any] {
        let requested = (body["productId"] as? String) ?? Self.productID
        guard let productID = Self.normalizeProductID(requested) else {
            return failure("invalid_product_id", "Producto no válido: \(requested).")
        }

        do {
            // Forces a StoreKit round-trip with the Apple ID (Apple guideline 3.1.1).
            try await AppStore.sync()
        } catch {
            let mapped = Self.mapStoreKitError(error)
            return failure(mapped.0, mapped.1, extra: ["productId": productID, "success": false])
        }

        let entitlements = await collectEntitlements(productID: productID)
        let latest = entitlements.first

        var payload: [String: Any] = [
            "status": "success",
            "action": "restore",
            "source": "restore",
            "productId": productID,
            "restoredCount": entitlements.count,
            "entitlements": entitlements,
            "success": latest != nil
        ]
        if let latest = latest {
            payload["purchaseToken"] = latest["transactionId"]
            payload["jws"] = latest["jws"]
            payload["transactionId"] = latest["transactionId"]
            payload["originalTransactionId"] = latest["originalTransactionId"]
        } else {
            payload["error"] = "not_found"
            payload["message"] = "No encontramos una suscripción activa en esta cuenta de Apple ID."
        }
        return payload
    }

    // MARK: - currentEntitlements

    private func handleCurrentEntitlements(body: [String: Any]) async -> [String: Any] {
        let requested = body["productId"] as? String
        let productID = requested.flatMap(Self.normalizeProductID) ?? Self.productID
        let entitlements = await collectEntitlements(productID: productID)
        let latest = entitlements.first

        var payload: [String: Any] = [
            "status": "success",
            "action": "currentEntitlements",
            "source": "currentEntitlements",
            "productId": productID,
            "count": entitlements.count,
            "entitlements": entitlements,
            "success": latest != nil,
            // Client-side hint only. NEVER use this to unlock Pro.
            "clientHintIsPro": latest != nil,
            "authoritative": false
        ]
        if let latest = latest {
            payload["purchaseToken"] = latest["transactionId"]
            payload["jws"] = latest["jws"]
            payload["transactionId"] = latest["transactionId"]
            payload["originalTransactionId"] = latest["originalTransactionId"]
        }
        return payload
    }

    // MARK: - products

    private func handleProducts(body: [String: Any]) async -> [String: Any] {
        let requested = (body["productId"] as? String) ?? Self.productID
        guard let productID = Self.normalizeProductID(requested) else {
            return failure("invalid_product_id", "Producto no válido: \(requested).")
        }

        do {
            let products = try await Product.products(for: [productID])
            guard let product = products.first else {
                return failure(
                    "product_not_found",
                    "StoreKit no encontró \(productID).",
                    extra: ["productId": productID]
                )
            }

            var item: [String: Any] = [
                "productId": product.id,
                "displayName": product.displayName,
                "description": product.description,
                "displayPrice": product.displayPrice,
                "price": NSDecimalNumber(decimal: product.price).doubleValue,
                "currencyCode": product.priceFormatStyle.currencyCode
            ]

            if let subscription = product.subscription {
                item["subscriptionPeriod"] = Self.isoPeriod(subscription.subscriptionPeriod)
                item["subscriptionGroupId"] = subscription.subscriptionGroupID
            }

            return [
                "status": "success",
                "action": "products",
                "products": [item]
            ]
        } catch {
            let mapped = Self.mapStoreKitError(error)
            return failure(mapped.0, mapped.1, extra: ["productId": productID])
        }
    }

    // MARK: - finish

    private func handleFinish(body: [String: Any]) async -> [String: Any] {
        guard let idString = body["transactionId"] as? String, let id = UInt64(idString) else {
            return failure("bad_request", "Falta transactionId numérico.")
        }

        if let cached = cachedTransaction(id: id) {
            await cached.finish()
            removeCachedTransaction(id: id)
            return ["status": "success", "action": "finish", "transactionId": idString]
        }

        if let found = await findTransaction(id: id) {
            await found.finish()
            return ["status": "success", "action": "finish", "transactionId": idString]
        }

        // Already finished or not owned by this Apple ID: idempotent success.
        return [
            "status": "success",
            "action": "finish",
            "transactionId": idString,
            "note": "transaction_not_found_but_idempotent"
        ]
    }

    // MARK: - Transaction updates

    private func startTransactionUpdatesListener() {
        guard updatesTask == nil else { return }
        updatesTask = Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self = self else { return }
                await self.handleTransactionUpdate(result)
            }
        }
    }

    private func handleTransactionUpdate(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        guard transaction.productID == Self.productID else { return }
        cache(result)
        if finishAfterDeliver {
            await transaction.finish()
        }
        var payload = purchasePayload(
            verification: result,
            status: "success",
            action: "update",
            source: "updates",
            transaction: transaction
        )
        payload["requiresVerification"] = true
        emit(payload, requestId: nil)
    }

    // MARK: - Payload builders

    private func purchasePayload(
        verification: VerificationResult<Transaction>,
        status: String,
        action: String,
        source: String,
        transaction explicitTransaction: Transaction? = nil
    ) -> [String: Any] {
        let transaction: Transaction
        if let explicitTransaction = explicitTransaction {
            transaction = explicitTransaction
        } else if case .verified(let value) = verification {
            transaction = value
        } else {
            return failure("unverified_transaction", "La transacción no está verificada por Apple.")
        }

        var payload: [String: Any] = [
            "status": status,
            "action": action,
            "source": source,
            "success": true,
            // The live web client reads `purchaseToken` first, then transactionId.
            "purchaseToken": String(transaction.id),
            "jws": verification.jwsRepresentation,
            "productId": transaction.productID,
            "transactionId": String(transaction.id),
            "originalTransactionId": String(transaction.originalID),
            "purchaseDate": Self.millis(transaction.purchaseDate),
            "ownershipType": String(describing: transaction.ownershipType),
            "isUpgraded": transaction.isUpgraded,
            "bundleId": Self.bundleID
        ]

        if let expires = transaction.expirationDate {
            payload["expiresDate"] = Self.millis(expires)
        }
        if let revocation = transaction.revocationDate {
            payload["revocationDate"] = Self.millis(revocation)
            payload["success"] = false
        }
        if let token = transaction.appAccountToken {
            payload["appAccountToken"] = token.uuidString.lowercased()
        }
        if let offerType = transaction.offerType {
            payload["offerType"] = String(describing: offerType)
        }

        return payload
    }

    private func failure(_ code: String, _ message: String, extra: [String: Any] = [:]) -> [String: Any] {
        var payload: [String: Any] = [
            "status": "error",
            "success": false,
            "code": code,
            "error": code,
            "message": message
        ]
        for (key, value) in extra {
            payload[key] = value
        }
        return payload
    }

    // MARK: - JS delivery

    private func emit(_ payload: [String: Any], requestId: String?) {
        var body = payload
        body["channel"] = Self.channelName
        body["contractVersion"] = Self.contractVersion
        if let requestId = requestId {
            body["requestId"] = requestId
        }

        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return
        }

        // U+2028 / U+2029 are valid JSON but illegal in old JS parsers.
        let safeJSON = json
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        let ridLiteral = requestId.map { Self.jsonLiteral($0) } ?? "null"

        let script = """
        (function(){
          var p = \(safeJSON);
          var rid = \(ridLiteral);
          if (window.__billionairePurchases && typeof window.__billionairePurchases.receive === "function") {
            window.__billionairePurchases.receive(p);
            return "handled";
          }
          if (rid && typeof window.__billionairePurchaseCallback === "function") {
            window.__billionairePurchaseCallback(rid, p);
            return "handled";
          }
          window.dispatchEvent(new CustomEvent("billionaire:purchases", { detail: p }));
          return "missing";
        })();
        """

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let webView = self.webView else {
                self.enqueue(body)
                return
            }
            webView.evaluateJavaScript(script) { result, error in
                if error != nil || (result as? String) == "missing" {
                    self.enqueue(body)
                }
            }
        }
    }

    private func enqueue(_ payload: [String: Any]) {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            self.outbox.append(payload)
            if self.outbox.count > self.maxOutbox {
                self.outbox.removeFirst(self.outbox.count - self.maxOutbox)
            }
        }
    }

    private func flushOutbox() {
        let pending: [[String: Any]] = stateQueue.sync {
            let copy = outbox
            outbox.removeAll()
            return copy
        }
        guard !pending.isEmpty else { return }
        for payload in pending {
            emit(payload, requestId: payload["requestId"] as? String)
        }
    }

    // MARK: - Transaction cache

    private func cache(_ verification: VerificationResult<Transaction>) {
        guard case .verified(let transaction) = verification else { return }
        stateQueue.async { [weak self] in
            self?.transactionCache[transaction.id] = verification
        }
    }

    private func cachedTransaction(id: UInt64) -> Transaction? {
        let verification: VerificationResult<Transaction>? = stateQueue.sync {
            transactionCache[id]
        }
        guard let verification = verification, case .verified(let transaction) = verification else {
            return nil
        }
        return transaction
    }

    private func removeCachedTransaction(id: UInt64) {
        stateQueue.async { [weak self] in
            self?.transactionCache.removeValue(forKey: id)
        }
    }

    private func findTransaction(id: UInt64) async -> Transaction? {
        for await result in Transaction.all {
            if case .verified(let transaction) = result, transaction.id == id {
                return transaction
            }
        }
        return nil
    }

    // MARK: - Entitlements

    private func firstActiveEntitlement(productID: String) async -> VerificationResult<Transaction>? {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard transaction.productID == productID else { continue }
            if transaction.revocationDate != nil { continue }
            if let expiry = transaction.expirationDate, expiry < Date() { continue }
            return result
        }
        return nil
    }

    private func collectEntitlements(productID: String) async -> [[String: Any]] {
        var items: [[String: Any]] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard transaction.productID == productID else { continue }
            if transaction.revocationDate != nil { continue }
            if let expiry = transaction.expirationDate, expiry < Date() { continue }
            items.append(purchasePayload(
                verification: result,
                status: "success",
                action: "currentEntitlements",
                source: "currentEntitlements",
                transaction: transaction
            ))
        }
        return items
    }

    // MARK: - Helpers

    /// Accepts both the bare SKU used by older web builds and the fully qualified
    /// App Store product ID. Anything else is rejected so a typo can never silently
    /// purchase a different product.
    static func normalizeProductID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == productID { return productID }
        if trimmed == bareProductID { return productID }
        return nil
    }

    private static func jsonLiteral(_ value: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "\"\""
    }

    private static func millis(_ date: Date) -> Double {
        return (date.timeIntervalSince1970 * 1000).rounded()
    }

    private static func isoPeriod(_ period: Product.SubscriptionPeriod) -> String {
        let unit: String
        switch period.unit {
        case .day: unit = "D"
        case .week: unit = "W"
        case .month: unit = "M"
        case .year: unit = "Y"
        @unknown default: unit = "D"
        }
        return "P\(period.value)\(unit)"
    }

    private static func mapStoreKitError(_ error: Error) -> (String, String) {
        if let storeKitError = error as? StoreKitError {
            switch storeKitError {
            case .userCancelled:
                return ("user_cancelled", "Compra cancelada.")
            case .networkError:
                return ("network_error", "No hay conexión con la App Store. Revisa tu internet e inténtalo de nuevo.")
            case .systemError:
                return ("storekit_system_error", "La App Store devolvió un error del sistema. Inténtalo más tarde.")
            case .notAvailableInStorefront:
                return ("not_available_in_storefront", "Este producto no está disponible en tu país.")
            case .notEntitled:
                return ("not_entitled", "La cuenta de Apple ID no tiene derecho a este producto.")
            default:
                return ("unknown_storekit_error", "Error de StoreKit: \(error.localizedDescription)")
            }
        }

        if let purchaseError = error as? Product.PurchaseError {
            switch purchaseError {
            case .productUnavailable:
                return ("product_unavailable", "El producto no está disponible para compra en este momento.")
            case .purchaseNotAllowed:
                return ("purchase_not_allowed", "Las compras están restringidas en este dispositivo (Control parental o MDM).")
            case .ineligibleForOffer:
                return ("ineligible_for_offer", "La cuenta no es elegible para esta oferta.")
            default:
                return ("purchase_failed", purchaseError.localizedDescription)
            }
        }

        return ("purchase_failed", error.localizedDescription)
    }
}

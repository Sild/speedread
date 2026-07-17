import Observation
import StoreKit

enum ProProduct: String, CaseIterable, Hashable, Identifiable, Sendable {
    case monthly = "com.sild.speedread.pro.monthly"
    case annual = "com.sild.speedread.pro.annual"
    case lifetime = "com.sild.speedread.pro.lifetime"

    var id: String {
        rawValue
    }

    var testDisplayPrice: String {
        switch self {
        case .monthly:
            "$4.99"
        case .annual:
            "$29.99"
        case .lifetime:
            "$79.99"
        }
    }
}

@MainActor
@Observable
final class PurchaseManager {
    enum Entitlement: Equatable, Sendable {
        case loading
        case free
        case subscription(ProProduct)
        case lifetime
    }

    enum TestingMode: Equatable, Sendable {
        case free
        case monthly
        case annual
        case lifetime
        case pending
        case cancelled
        case verificationFailure
        case productUnavailable
        case offlineAnnual
    }

    private(set) var entitlement: Entitlement = .loading
    private(set) var products: [ProProduct: Product] = [:]
    private(set) var isWorking = false
    private(set) var errorMessage: String?

    private let testingMode: TestingMode?
    @ObservationIgnored
    private var updatesTask: Task<Void, Never>?
    private var hasStarted = false

    init(testingMode: TestingMode? = nil) {
        self.testingMode = testingMode
    }

    deinit {
        updatesTask?.cancel()
    }

    var isReady: Bool {
        entitlement != .loading
    }

    var hasProAccess: Bool {
        switch entitlement {
        case .subscription, .lifetime:
            true
        case .loading, .free:
            false
        }
    }

    var accessPolicy: ProAccessPolicy {
        ProAccessPolicy(hasProAccess: hasProAccess)
    }

    var hasActiveSubscription: Bool {
        if case .subscription = entitlement {
            return true
        }
        return false
    }

    func displayPrice(for product: ProProduct) -> String? {
        if let loadedProduct = products[product] {
            return loadedProduct.displayPrice
        }
        guard testingMode != nil, testingMode != .productUnavailable, testingMode != .offlineAnnual else {
            return nil
        }
        return product.testDisplayPrice
    }

    func annualMonthlyEquivalent() -> String? {
        if let annualProduct = products[.annual] {
            return (annualProduct.price / 12).formatted(annualProduct.priceFormatStyle)
        }
        guard testingMode != nil, testingMode != .productUnavailable, testingMode != .offlineAnnual else {
            return nil
        }
        return "$2.50"
    }

    func start() async {
        guard !hasStarted else {
            return
        }
        hasStarted = true

        if let testingMode {
            entitlement = Self.testEntitlement(for: testingMode)
            return
        }

        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled, let self else {
                    return
                }
                await handle(transaction: result)
            }
        }
        await refreshEntitlement()
        await loadProducts()
    }

    func purchase(_ selectedProduct: ProProduct) async {
        guard !isWorking else {
            return
        }
        if let testingMode {
            handleTestPurchase(selectedProduct, mode: testingMode)
            return
        }
        guard let product = products[selectedProduct] else {
            errorMessage = String(localized: "pro.error.productUnavailable")
            return
        }

        isWorking = true
        defer { isWorking = false }
        do {
            switch try await product.purchase() {
            case let .success(result):
                guard case let .verified(transaction) = result else {
                    errorMessage = String(localized: "pro.error.verification")
                    return
                }
                await transaction.finish()
                await refreshEntitlement()
            case .pending, .userCancelled:
                return
            @unknown default:
                errorMessage = String(localized: "pro.error.purchase")
            }
        } catch {
            errorMessage = String(localized: "pro.error.purchase")
        }
    }

    func restore() async {
        guard !isWorking else {
            return
        }
        if testingMode != nil {
            entitlement = .lifetime
            return
        }

        isWorking = true
        defer { isWorking = false }
        do {
            try await AppStore.sync()
            await refreshEntitlement()
            if !hasProAccess {
                errorMessage = String(localized: "pro.error.nothingToRestore")
            }
        } catch {
            errorMessage = String(localized: "pro.error.restore")
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        hasStarted = false
    }

    func refreshEntitlement() async {
        guard testingMode == nil else {
            return
        }
        var records: [EntitlementRecord] = []
        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result,
                  let product = ProProduct(rawValue: transaction.productID)
            else {
                continue
            }
            records.append(
                EntitlementRecord(
                    product: product,
                    expirationDate: transaction.expirationDate,
                    revocationDate: transaction.revocationDate,
                    isUpgraded: transaction.isUpgraded
                )
            )
        }
        entitlement = Self.resolveEntitlement(from: records, now: .now)
    }

    private func loadProducts() async {
        do {
            let loadedProducts = try await Product.products(for: ProProduct.allCases.map(\.rawValue))
            products = Dictionary(
                uniqueKeysWithValues: loadedProducts.compactMap { product in
                    ProProduct(rawValue: product.id).map { ($0, product) }
                }
            )
        } catch {
            products = [:]
        }
    }

    private func handle(transaction result: VerificationResult<Transaction>) async {
        guard case let .verified(transaction) = result else {
            errorMessage = String(localized: "pro.error.verification")
            return
        }
        guard ProProduct(rawValue: transaction.productID) != nil else {
            return
        }
        await transaction.finish()
        await refreshEntitlement()
    }

    private func handleTestPurchase(_ product: ProProduct, mode: TestingMode) {
        switch mode {
        case .pending, .cancelled:
            return
        case .verificationFailure:
            errorMessage = String(localized: "pro.error.verification")
        case .productUnavailable, .offlineAnnual:
            errorMessage = String(localized: "pro.error.productUnavailable")
        case .free, .monthly, .annual, .lifetime:
            entitlement = product == .lifetime ? .lifetime : .subscription(product)
        }
    }

    private static func testEntitlement(for mode: TestingMode) -> Entitlement {
        switch mode {
        case .monthly:
            .subscription(.monthly)
        case .annual, .offlineAnnual:
            .subscription(.annual)
        case .lifetime:
            .lifetime
        case .free, .pending, .cancelled, .verificationFailure, .productUnavailable:
            .free
        }
    }

    nonisolated static func resolveEntitlement(
        from records: [EntitlementRecord],
        now: Date
    ) -> Entitlement {
        var subscription: ProProduct?
        for record in records {
            guard record.revocationDate == nil, !record.isUpgraded else {
                continue
            }
            if record.product == .lifetime {
                return .lifetime
            }
            guard record.expirationDate.map({ $0 > now }) ?? false else {
                continue
            }
            subscription = record.product
        }
        if let subscription {
            return .subscription(subscription)
        }
        return .free
    }
}

struct EntitlementRecord: Equatable, Sendable {
    let product: ProProduct
    let expirationDate: Date?
    let revocationDate: Date?
    let isUpgraded: Bool
}

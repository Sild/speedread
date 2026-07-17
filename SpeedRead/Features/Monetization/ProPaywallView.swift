import StoreKit
import SwiftUI

struct ProPaywallView: View {
    @Environment(\.dismiss) private var dismiss

    @State var purchaseManager: PurchaseManager
    @State private var presentsManageSubscriptions = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SpeedReadSpacing.small) {
                    header
                    features
                    entitlementContent
                    restoreButton
                    legalLinks
                }
                .padding(.horizontal, SpeedReadSpacing.large)
                .padding(.vertical, SpeedReadSpacing.standard)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .editorialCanvas()
            .navigationTitle("pro.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.close") {
                        dismiss()
                    }
                    .accessibilityIdentifier("pro.close")
                }
            }
        }
        .interactiveDismissDisabled(purchaseManager.isWorking)
        .manageSubscriptionsSheet(isPresented: $presentsManageSubscriptions)
        .alert("pro.error.title", isPresented: errorPresented) {
            Button("action.ok") {
                purchaseManager.dismissError()
            }
        } message: {
            Text(purchaseManager.errorMessage ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SpeedReadSpacing.small) {
            Image(systemName: "crown.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(SpeedReadPalette.focus)
                .accessibilityHidden(true)
            Text("pro.headline")
                .font(.largeTitle.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text("pro.intro")
                .font(.body)
                .foregroundStyle(SpeedReadPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: SpeedReadSpacing.medium) {
            feature("pro.feature.unlimitedLibrary", symbol: "books.vertical.fill")
            feature("pro.feature.privateSync", symbol: "checkmark.icloud.fill")
        }
        .padding(SpeedReadSpacing.standard)
        .background(SpeedReadPalette.raised, in: RoundedRectangle(cornerRadius: SpeedReadRadius.card))
    }

    private func feature(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(SpeedReadPalette.focus)
        }
    }

    @ViewBuilder
    private var entitlementContent: some View {
        switch purchaseManager.entitlement {
        case .loading:
            ProgressView("pro.checkingPurchase")
                .frame(maxWidth: .infinity)
        case .free:
            purchaseOptions
        case .subscription:
            activeCard(title: "pro.active.subscription", message: "pro.active.subscription.message")
            Button("pro.manageSubscription") {
                presentsManageSubscriptions = true
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(SpeedReadPalette.onFocus)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("pro.manageSubscription")
        case .lifetime:
            activeCard(title: "pro.active.lifetime", message: "pro.active.lifetime.message")
        }
    }

    private var purchaseOptions: some View {
        VStack(spacing: SpeedReadSpacing.medium) {
            purchaseButton(for: .monthly)
            purchaseButton(for: .annual, recommended: true)
            purchaseButton(for: .lifetime)
        }
    }

    private func purchaseButton(for product: ProProduct, recommended: Bool = false) -> some View {
        Button {
            Task {
                await purchaseManager.purchase(product)
            }
        } label: {
            purchaseButtonLabel(for: product, recommended: recommended)
                .padding(SpeedReadSpacing.standard)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .background(
                    SpeedReadPalette.raised,
                    in: RoundedRectangle(cornerRadius: SpeedReadRadius.card)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: SpeedReadRadius.card)
                        .stroke(recommended ? SpeedReadPalette.focus : .clear, lineWidth: 2)
                }
        }
        .buttonStyle(.plain)
        .disabled(purchaseManager.isWorking || purchaseManager.displayPrice(for: product) == nil)
        .accessibilityIdentifier("pro.purchase.\(product.id)")
    }

    private func purchaseButtonLabel(for product: ProProduct, recommended: Bool) -> some View {
        HStack(alignment: .center, spacing: SpeedReadSpacing.standard) {
            VStack(alignment: .leading, spacing: SpeedReadSpacing.xSmall) {
                HStack(spacing: SpeedReadSpacing.small) {
                    Text(title(for: product))
                        .font(.headline)
                    if recommended {
                        Text("pro.bestValue")
                            .font(.caption.bold())
                            .fixedSize(horizontal: true, vertical: true)
                            .foregroundStyle(SpeedReadPalette.onFocus)
                            .padding(.horizontal, SpeedReadSpacing.small)
                            .padding(.vertical, SpeedReadSpacing.xSmall)
                            .background(SpeedReadPalette.focus, in: Capsule())
                    }
                }
                .layoutPriority(1)
                if let detail = detail(for: product) {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(SpeedReadPalette.secondaryText)
                }
            }
            Spacer()
            if purchaseManager.isWorking {
                ProgressView()
            } else if let price = purchaseManager.displayPrice(for: product) {
                Text(price)
                    .font(.headline.monospacedDigit())
            } else {
                Text("pro.productUnavailable.short")
                    .font(.footnote)
                    .foregroundStyle(SpeedReadPalette.secondaryText)
            }
        }
    }

    private func activeCard(title: LocalizedStringKey, message: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: SpeedReadSpacing.small) {
            Label(title, systemImage: "checkmark.seal.fill")
                .font(.title3.bold())
                .foregroundStyle(SpeedReadPalette.focus)
            Text(message)
                .foregroundStyle(SpeedReadPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SpeedReadSpacing.standard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SpeedReadPalette.raised, in: RoundedRectangle(cornerRadius: SpeedReadRadius.card))
        .accessibilityIdentifier("pro.active")
    }

    private var restoreButton: some View {
        Button("pro.restore") {
            Task {
                await purchaseManager.restore()
            }
        }
        .disabled(purchaseManager.isWorking)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("pro.restore")
    }

    private var legalLinks: some View {
        HStack(spacing: SpeedReadSpacing.small) {
            if let supportURL = URL(string: "https://sild.github.io/speedread/support.html") {
                Link("pro.support", destination: supportURL)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("pro.support")
            }
            if let privacyPolicyURL = URL(string: "https://sild.github.io/speedread/privacy.html") {
                Link("pro.privacyPolicy", destination: privacyPolicyURL)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("pro.privacyPolicy")
            }
            if let termsOfUseURL = URL(
                string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"
            ) {
                Link("pro.termsOfUse", destination: termsOfUseURL)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("pro.termsOfUse")
            }
        }
        .font(.footnote)
        .frame(maxWidth: .infinity)
    }

    private func title(for product: ProProduct) -> LocalizedStringKey {
        switch product {
        case .monthly:
            "pro.product.monthly"
        case .annual:
            "pro.product.annual"
        case .lifetime:
            "pro.product.lifetime"
        }
    }

    private func detail(for product: ProProduct) -> String? {
        switch product {
        case .monthly:
            return String(localized: "pro.product.monthly.detail")
        case .annual:
            guard let monthlyEquivalent = purchaseManager.annualMonthlyEquivalent() else {
                return String(localized: "pro.product.annual.detail")
            }
            return String.localizedStringWithFormat(
                String(localized: "pro.product.annual.equivalent"),
                monthlyEquivalent
            )
        case .lifetime:
            return String(localized: "pro.product.lifetime.detail")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { purchaseManager.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    purchaseManager.dismissError()
                }
            }
        )
    }
}

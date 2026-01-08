//
//  DonationService.swift
//  AIGoodbye
//
//  In-App Purchase handling using StoreKit 2
//

import Foundation
import StoreKit
import Combine

@MainActor
class DonationService: ObservableObject {
    @Published var products: [Product] = []
    @Published var purchaseInProgress = false
    @Published var purchaseError: String?
    @Published var showThankYou = false

    private var transactionListener: Task<Void, Error>?

    init() {
        transactionListener = listenForTransactions()
        Task {
            await loadProducts()
        }
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - Load Products

    func loadProducts() async {
        do {
            let productIds = DonationTier.allCases.map { $0.rawValue }
            products = try await Product.products(for: productIds)
                .sorted { $0.price < $1.price }
        } catch {
            print("Failed to load products: \(error)")
        }
    }

    // MARK: - Purchase

    func purchase(_ tier: DonationTier) async {
        guard let product = products.first(where: { $0.id == tier.rawValue }) else {
            purchaseError = "Product not found"
            return
        }

        purchaseInProgress = true
        purchaseError = nil

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                let transaction = try Self.checkVerified(verification)

                // Consumable IAP - finish immediately
                await transaction.finish()

                showThankYou = true

            case .userCancelled:
                break

            case .pending:
                purchaseError = "Purchase is pending approval"

            @unknown default:
                purchaseError = "Unknown purchase result"
            }
        } catch {
            purchaseError = error.localizedDescription
        }

        purchaseInProgress = false
    }

    // MARK: - Transaction Listener

    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached {
            for await result in Transaction.updates {
                do {
                    let transaction = try Self.checkVerified(result)
                    await transaction.finish()
                } catch {
                    print("Transaction verification failed: \(error)")
                }
            }
        }
    }

    private nonisolated static func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let value):
            return value
        }
    }

    // MARK: - Restore Purchases

    func restorePurchases() async {
        // For consumables, there's nothing to restore
        // But we can sync with App Store
        try? await AppStore.sync()
    }
}

// MARK: - Errors

enum StoreError: LocalizedError {
    case failedVerification

    var errorDescription: String? {
        switch self {
        case .failedVerification:
            return "Purchase verification failed"
        }
    }
}

// MARK: - Thank You View

import SwiftUI

struct ThankYouView: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "heart.fill")
                .font(.system(size: 60))
                .foregroundStyle(.pink)
                .symbolEffect(.bounce)

            Text("Thank You!")
                .font(.largeTitle.bold())

            Text("Your support means the world to us and helps keep AiGoodbye free for everyone.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("Continue") {
                isPresented = false
            }
            .buttonStyle(.borderedProminent)
            .tint(.pink)
        }
        .padding(32)
    }
}

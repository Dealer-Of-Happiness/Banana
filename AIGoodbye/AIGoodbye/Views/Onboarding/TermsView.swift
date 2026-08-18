//
//  TermsView.swift
//  AIGoodbye
//
//  First-launch welcome and terms acceptance screen, driven by LegalText.
//

import SwiftUI

struct TermsView: View {
    @Binding var hasAcceptedTerms: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                cards
                agreeArea
            }
            .padding(.horizontal, 20)
            .padding(.top, 32)
            .padding(.bottom, 24)
        }
        .background(Color(.systemBackground))
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(height: 100)
                .accessibilityHidden(true)

            Text(LegalText.appName)
                .font(.largeTitle.bold())

            Text(LegalText.tagline)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Section Cards

    private var cards: some View {
        VStack(spacing: 12) {
            ForEach(LegalText.sections.indices, id: \.self) { index in
                sectionCard(LegalText.sections[index])
            }
        }
    }

    private func sectionCard(_ section: (title: String, body: String, icon: String)) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: section.icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(section.title)
                    .font(.headline)

                Text(section.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Agree Button

    private var agreeArea: some View {
        VStack(spacing: 12) {
            Text("By continuing you agree to use AiGoodbye at your own discretion.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                hasAcceptedTerms = true
            } label: {
                Text("Agree and Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Agree and Continue")
            .accessibilityHint("Accepts the terms and opens the app")
        }
        .padding(.top, 8)
    }
}

#Preview {
    TermsView(hasAcceptedTerms: .constant(false))
}

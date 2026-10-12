//
//  TermsView.swift
//  AIGoodbye
//
//  First-launch welcome and terms acceptance screen, driven by LegalText.
//
//  Short on purpose. Six full cards pushed the only button two screens
//  below the fold on an iPhone, so the first thing a new buyer did was
//  scroll through a wall of text looking for how to start. Each card now
//  shows its first sentence, the full text is one tap away (the same
//  About & Legal screen Settings shows), and the button never scrolls.
//

import SwiftUI

struct TermsView: View {
    @Binding var hasAcceptedTerms: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    cards
                }
                .padding(.horizontal, 20)
                .padding(.top, 32)
                .padding(.bottom, 24)
                .frame(maxWidth: 600)          // readable width on iPad
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                agreeArea
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: 600)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
            // Only this first screen is bare; the pushed full text keeps its
            // bar and Back button.
            .toolbar(.hidden, for: .navigationBar)
        }
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
            ForEach(LegalText.onboardingSections.indices, id: \.self) { index in
                sectionCard(LegalText.onboardingSections[index])
            }

            NavigationLink {
                AboutView()
            } label: {
                HStack(spacing: 4) {
                    Text("Read more")
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
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

                Text(Self.firstSentence(of: section.body))
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

    /// Split at runtime, so every language gets its summary line from the
    /// translation it already has rather than five more keys per language.
    /// The system sentence breaker knows "。" and "!" as well as ".".
    static func firstSentence(of text: String) -> String {
        var first: String?
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { sentence, _, _, stop in
            first = sentence
            stop = true
        }
        let trimmed = (first ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? text : trimmed
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
    }
}

#Preview {
    TermsView(hasAcceptedTerms: .constant(false))
}

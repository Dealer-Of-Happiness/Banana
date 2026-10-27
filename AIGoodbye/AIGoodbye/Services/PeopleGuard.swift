//
//  PeopleGuard.swift
//  AIGoodbye
//
//  Questions about people, for the smallest models.
//
//  Qwen3.5 0.8B invents a life for anyone it has never heard of - an actor
//  "Karl von Gimborn" with a film "Der letzte König" and sequels, for a
//  tester asking about himself - in any phrasing, and in German even when
//  told not to. Asked on the side whether it knows the person, it answers
//  reliably. So before such a model answers, this finds out who the
//  message is about and whether the model knows them, and keeps track
//  through the chat: once it has said it does not know someone, "Ist er
//  ein Schauspieler?" a turn later gets the same honest answer, rather
//  than the invented career the tester saw after his second question.
//

import Foundation

/// What a chat has learned about the people in it.
nonisolated struct PeopleState: Equatable, Sendable {
    /// The name the user gave as their own ("Ich heiße ...").
    var userName: String?
    /// People the model said it does not know.
    var unknownNames: [String] = []
    /// The last question was about one of them, so "er", "sie", "him"
    /// in the next one most likely is too.
    var lastTurnAboutUnknown = false
    /// The last question was about the user.
    var lastTurnAboutUser = false
}

nonisolated enum PeopleGuard {

    struct Outcome: Equatable {
        /// Whether the model knows the person the message is about; nil
        /// when it is about nobody in particular (or nobody was asked).
        var personKnown: Bool?
        /// The answer the app gives itself, if any (see `TurnContext.fixedAnswer`).
        var fixed: String?
        /// The name the user introduced themselves with in this message.
        var introducedName: String?
    }

    /// Decide how the model may answer `question`.
    ///
    /// - Parameter probe: asks the loaded model a short side question
    ///   (prompt, maximum tokens) on a throwaway session and returns its
    ///   raw answer; nil if it could not be asked.
    static func resolve(
        question: String,
        hasImage: Bool,
        appLanguage: AppLanguage,
        fallbackLanguage: AppLanguage = .english,
        rememberedFacts: [String] = [],
        state: inout PeopleState,
        probe: (String, Int) async -> String?
    ) async -> Outcome {
        var outcome = Outcome()

        // The user saying who they are.
        if let name = TurnContext.selfIntroductionName(in: question) {
            state.userName = name
            outcome.introducedName = name
            // Only that ("Ich heiße Scott von Gimborn."): greeted by the app.
            // Told the name and nothing else, the model introduced the user
            // to himself as a character from a TV series.
            if !hasImage, !TurnContext.isQuestionLike(question),
               question.split(whereSeparator: { $0.isWhitespace }).count <= 12 {
                state.lastTurnAboutUnknown = false
                state.lastTurnAboutUser = false
                let language = TurnContext.replyLanguage(for: question, appLanguage: appLanguage) ?? fallbackLanguage
                outcome.fixed = TurnContext.Phrases.for(language).greeting(name)
                return outcome
            }
        }

        // About the user: "Wer bin ich?", "Bin ich ein Schauspieler?", or
        // a question naming the name they gave as their own.
        let namesUser = state.userName.map { question.localizedCaseInsensitiveContains($0) } ?? false
        let continuesAboutUser = state.lastTurnAboutUser
            && TurnContext.refersBackToSomeone(question) && TurnContext.isQuestionLike(question)
        let aboutUser = TurnContext.asksWhoTheUserIs(question)
            || (namesUser && outcome.introducedName == nil && TurnContext.isQuestionLike(question))
            || continuesAboutUser
        if aboutUser {
            state.lastTurnAboutUnknown = false
            state.lastTurnAboutUser = true
            outcome.fixed = TurnContext.fixedAnswer(
                for: question, hasImage: hasImage, personKnown: nil, appLanguage: appLanguage,
                fallbackLanguage: fallbackLanguage, rememberedFacts: rememberedFacts,
                asksAboutUser: true, userName: state.userName
            )
            return outcome
        }

        state.lastTurnAboutUser = false

        // The app's own developer is answered by the app.
        if TurnContext.mentionsDeveloper(question) {
            state.lastTurnAboutUnknown = false
            outcome.fixed = TurnContext.fixedAnswer(
                for: question, hasImage: hasImage, personKnown: nil, appLanguage: appLanguage,
                fallbackLanguage: fallbackLanguage, asksAboutUser: false
            )
            return outcome
        }

        // More about someone the model already said it does not know: by
        // name, or as "er"/"sie"/"him" in the very next question.
        let knownUnknown = state.unknownNames.first { question.localizedCaseInsensitiveContains($0) }
        let continuesAboutUnknown = state.lastTurnAboutUnknown
            && TurnContext.refersBackToSomeone(question) && TurnContext.isQuestionLike(question)
        if knownUnknown != nil || continuesAboutUnknown {
            outcome.personKnown = false
        } else if outcome.introducedName == nil,
                  TurnContext.isQuestionLike(question) || TurnContext.asksWhoSomeoneIs(question),
                  let answer = await probe(TurnContext.nameProbe(for: question), 12),
                  let name = TurnContext.personName(fromProbe: answer, question: question),
                  !(state.userName.map { name.localizedCaseInsensitiveContains($0) || $0.localizedCaseInsensitiveContains(name) } ?? false),
                  !TurnContext.mentionsDeveloper(name),
                  let knows = await probe(TurnContext.identityProbe(for: name), 4).flatMap(TurnContext.yesOrNo) {
            outcome.personKnown = knows
            if !knows, !state.unknownNames.contains(name) { state.unknownNames.append(name) }
        }

        state.lastTurnAboutUnknown = outcome.personKnown == false
        outcome.fixed = TurnContext.fixedAnswer(
            for: question, hasImage: hasImage, personKnown: outcome.personKnown, appLanguage: appLanguage,
            fallbackLanguage: fallbackLanguage, asksAboutUser: false
        )
        return outcome
    }
}

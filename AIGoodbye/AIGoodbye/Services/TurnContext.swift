//
//  TurnContext.swift
//  AIGoodbye
//
//  What a model cannot know by itself about the message it is answering:
//  which language to answer in, the date and time when the question is
//  about them, and - for "who is ...?" - a reminder that "I don't know
//  this person" is an answer. One short note in parentheses, in the
//  answer's language, put in front of the message the model sees. Never
//  stored, never shown.
//
//  Measured on Qwen3.5 0.8B (the model for 4 GB iPhones) with German
//  questions from a tester's report: the right time instead of a made-up
//  one, German answers to German questions about photos instead of English
//  ones, and fewer invented biographies. In front of the question, and in
//  its language: after it, "(Antworte auf Deutsch.)" turned "Wie viel ist
//  2 + 2? Antworte nur mit der Zahl." into the answer "2".
//

import Foundation
import NaturalLanguage

nonisolated enum TurnContext {

    /// The prompt the model receives: `prompt` with the note in front, or
    /// `prompt` unchanged when there is nothing to say.
    ///
    /// - Parameters:
    ///   - prompt: what goes to the model (it may carry retrieved document
    ///     passages around the question).
    ///   - question: what the user asked, alone. The language and the
    ///     kind of question are judged on this.
    ///   - hasImage: a picture goes with the message. The note then follows
    ///     the question instead of leading it: in front, it made the
    ///     smallest model open half its descriptions of a cartoon frog with
    ///     "Cartoon-Frosthund" or "Cartoon-Frosthaken"; after it, none of
    ///     24 did, and all 24 were still in German.
    static func wrap(
        _ prompt: String,
        question: String,
        appLanguage: AppLanguage,
        personKnown: Bool? = nil,
        introducedName: String? = nil,
        noNamedPerson: Bool = false,
        hasImage: Bool = false,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        guard let note = note(for: question, appLanguage: appLanguage, personKnown: personKnown,
                              introducedName: introducedName, noNamedPerson: noNamedPerson,
                              now: now, timeZone: timeZone) else {
            return prompt
        }
        return hasImage ? prompt + "\n\n" + note : note + "\n\n" + prompt
    }

    /// The note for `question`, or nil when there is nothing to add.
    ///
    /// - Parameter personKnown: for a "who is" question, whether the model
    ///   said it knows the person (`MLXService.knowsPerson`); nil when it
    ///   was not asked.
    /// - Parameter introducedName: the name the user just gave as their own
    ///   ("Ich heiße ..."), which the model is told and told not to embroider.
    /// - Parameter noNamedPerson: the model was asked who the message is
    ///   about and named nobody ("Infos über Berlin"), so there is no person
    ///   to be careful about.
    static func note(
        for question: String,
        appLanguage: AppLanguage,
        personKnown: Bool? = nil,
        introducedName: String? = nil,
        noNamedPerson: Bool = false,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String? {
        let language = replyLanguage(for: question, appLanguage: appLanguage)
        let phrases = Phrases.for(language ?? .english)
        var parts: [String] = []
        if asksAboutDateOrTime(question) {
            parts.append(phrases.now(dateLine(now: now, timeZone: timeZone, language: language)))
        }
        if let introducedName {
            parts.append(phrases.userIntro(introducedName))
        }
        if mentionsDeveloper(question) {
            parts.append(phrases.developerNote)
        } else if personKnown == false {
            parts.append(phrases.unknownPersonCertain)
        } else if personKnown == nil, !noNamedPerson, asksWhoSomeoneIs(question) {
            parts.append(phrases.unknownPerson)
        }
        if language != nil {
            parts.append(phrases.answerIn)
        }
        guard !parts.isEmpty else { return nil }
        return "(" + parts.joined(separator: " ") + ")"
    }

    /// An answer the app gives itself, in place of the smallest models'
    /// own, or nil to let the model answer.
    ///
    /// Asked "Wer ist Scott von Gimborn?", Qwen3.5 0.8B wrote a career,
    /// films and a birthday for a private person - every time, whatever
    /// the note in front of the question said, while the same model,
    /// asked separately, said plainly that it does not know him. So when
    /// it has said that (`personKnown == false`), the app answers that it
    /// does not know the person. The same for the app's own developer,
    /// whom it turned into a footballer: the app says who he is. Only for
    /// questions without a picture: a photo may show who someone is.
    ///
    /// "Who am I?" too: the model described itself instead. The app says
    /// what it knows about the user - what they say in the chat, and the
    /// facts they asked it to remember, listed.
    ///
    /// - Parameters:
    ///   - asksAboutUser: the question is about the user (see `PeopleGuard`,
    ///     which also counts questions naming the user's own name).
    ///   - userName: the name the user gave as their own, if any.
    static func fixedAnswer(
        for question: String,
        hasImage: Bool,
        personKnown: Bool?,
        appLanguage: AppLanguage,
        fallbackLanguage: AppLanguage = .english,
        rememberedFacts: [String] = [],
        asksAboutUser: Bool? = nil,
        userName: String? = nil
    ) -> String? {
        guard !hasImage else { return nil }
        let phrases = Phrases.for(replyLanguage(for: question, appLanguage: appLanguage) ?? fallbackLanguage)
        if asksAboutUser ?? asksWhoTheUserIs(question) {
            var answer = phrases.aboutUserAnswer
            if let userName { answer += " " + phrases.userNameIs(userName) }
            guard !rememberedFacts.isEmpty else { return answer }
            return answer + "\n\n" + phrases.rememberedIntro + "\n"
                + rememberedFacts.map { "- " + $0 }.joined(separator: "\n")
        }
        if mentionsDeveloper(question) {
            return asksWhoSomeoneIs(question) ? phrases.developerAnswer : nil
        }
        // Someone the model said it does not know, asked about in any form
        // ("Wer ist ...?", "Was macht ...?", "Ist er Schauspieler?").
        if personKnown == false, asksWhoSomeoneIs(question) || isQuestionLike(question) {
            return phrases.dontKnowAnswer
        }
        return nil
    }

    // MARK: - Language

    /// The language to answer in: the one chosen in Settings, or with
    /// Automatic the language the message is clearly written in.
    ///
    /// Small models drift into English, above all with a picture attached:
    /// a German question about a photo was answered in English although the
    /// system prompt says "the same language the user writes to you".
    /// Nil when there is no clear answer (a one-word message, a number):
    /// the system prompt's rule stands.
    static func replyLanguage(for text: String, appLanguage: AppLanguage) -> AppLanguage? {
        if appLanguage != .automatic { return appLanguage }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = supported.map(\.0)
        recognizer.processString(trimmed)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= 0.6 else { return nil }
        return supported.first { $0.0 == language }?.1
    }

    /// The language the app speaks to the user: the one chosen in Settings,
    /// or with Automatic the device's. For prompts the app writes itself
    /// (describe the surroundings, summaries), where there is no message
    /// of the user's to take the language from: "the same language the user
    /// writes to you" then meant the English of the app's own prompt, and a
    /// German phone described the room in English.
    static func uiLanguage(_ appLanguage: AppLanguage) -> AppLanguage {
        if appLanguage != .automatic { return appLanguage }
        return L10n.deviceLanguageCode.flatMap(RecordingSummarizer.language(forCode:)) ?? .english
    }

    /// The languages the app speaks, as NaturalLanguage names them.
    private static let supported: [(NLLanguage, AppLanguage)] = [
        (.english, .english), (.simplifiedChinese, .mandarin), (.traditionalChinese, .cantonese),
        (.russian, .russian), (.ukrainian, .ukrainian), (.korean, .korean), (.japanese, .japanese),
        (.french, .french), (.german, .german), (.greek, .greek), (.italian, .italian),
        (.spanish, .spanish), (.portuguese, .portuguese),
    ]

    // MARK: - What the question is about

    /// Whether the message asks about the date, the time or the day.
    ///
    /// Only then is the clock added. Without it the smallest model made a
    /// time up ("Es ist 19:00 Uhr" at 11:11); with a date and time under
    /// every message it mixed those numbers into sums.
    static func asksAboutDateOrTime(_ text: String) -> Bool {
        matches(text, datePatterns)
    }

    /// Whether the message asks who someone is ("Wer ist ...?", "Tell me
    /// about ..."). The smallest model invented a career, films and a
    /// birthday for a private person; a reminder right at the question
    /// made it say it does not know them, and well-known people were still
    /// answered.
    static func asksWhoSomeoneIs(_ text: String) -> Bool {
        (matches(text, personPatterns) || isJustAName(text)) && !asksWhoTheUserIs(text)
    }

    /// A message that is nothing but a name ("Scott von Gimborn",
    /// "Albert Einstein?"): to a chat model that reads as "tell me about
    /// this person", and the smallest one wrote a career for it. Greetings
    /// and thanks with a name in them are not ("Hallo Scott").
    static func isJustAName(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "?!.…？！。")))
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard (2...5).contains(tokens.count) else { return false }
        var capitalized = 0
        for token in tokens {
            let lower = token.lowercased()
            if nameStopWords.contains(lower.trimmingCharacters(in: .punctuationCharacters)) { return false }
            if nameParticles.contains(lower) { continue }
            guard let first = token.first, first.isUppercase,
                  token.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" || $0 == "’" || $0 == "." }) else { return false }
            capitalized += 1
        }
        return capitalized >= 2
    }

    private static let nameParticles: Set<String> = [
        "von", "van", "vom", "de", "der", "den", "del", "della", "di", "da", "du", "dos", "das",
        "zu", "la", "le", "bin", "ibn", "al", "el", "ten", "ter", "y", "e",
    ]

    /// Words that make a short capitalized message a greeting, thanks or a
    /// wish rather than a name, in the app's languages that capitalize.
    private static let nameStopWords: Set<String> = [
        "hallo", "hello", "hi", "hey", "servus", "moin", "guten", "gute", "morgen", "tag", "abend", "nacht",
        "danke", "dank", "vielen", "thanks", "thank", "ok", "okay", "bitte", "please", "ja", "nein", "yes", "no",
        "frohe", "fröhliche", "happy", "merry", "schönen", "schöne", "liebe", "lieber", "dear", "sehr", "geehrte",
        "geehrter", "good", "morning", "evening", "night", "bonjour", "bonsoir", "merci", "salut", "hola",
        "gracias", "buenos", "buenas", "ciao", "grazie", "buongiorno", "olá", "ola", "obrigado", "obrigada",
        "bom", "boa", "привет", "спасибо", "здравствуйте", "привіт", "дякую", "γεια", "ευχαριστώ",
        "test", "testing", "weiter", "continue", "stop", "ende",
    ]

    /// Whether the message asks who the user is, or what the app knows
    /// about them. The smallest model answered "Wer bin ich?" by
    /// describing itself, every time, even after the user had said who
    /// they are.
    static func asksWhoTheUserIs(_ text: String) -> Bool {
        matches(text, selfPatterns)
    }

    /// Whether the message asks for something - a question, or "tell me",
    /// "describe" - rather than stating something.
    static func isQuestionLike(_ text: String) -> Bool {
        if text.contains("?") || text.contains("？") || text.contains("¿") || text.contains(";") { return true }
        return matches(text, requestPatterns)
    }

    /// Whether the message refers to someone already mentioned ("Ist er
    /// ein Schauspieler?", "Tell me more about her").
    static func refersBackToSomeone(_ text: String) -> Bool {
        matches(text, pronounPatterns)
    }

    /// The name in "Ich heiße ...", "My name is ...": the user introducing
    /// themselves, which is neither a question about a stranger nor
    /// something to invent a biography for.
    static func selfIntroductionName(in text: String) -> String? {
        let particle = #"(?:von|van|de|der|den|zu|da|di|del|la|le|bin|al|ten|ter)"#
        let name = #"([\p{Lu}][\p{L}'\-]*(?:\s+(?:"# + particle + #"\s+)?[\p{Lu}][\p{L}'\-]*){0,3})"#
        let triggers = #"(?i:ich hei(?:ß|ss)e|mein name ist|nenn mich|my name is|i'm called|i am called|call me|je m'appelle|mon nom est|me llamo|mi nombre es|mi chiamo|il mio nome è|me chamo|meu nome é|меня зовут|мене звати|με λένε|ονομάζομαι)"#
        guard let regex = try? NSRegularExpression(pattern: triggers + #"\s+"# + name) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let found = Range(match.range(at: 1), in: text) else { return nil }
        let candidate = String(text[found]).trimmingCharacters(in: .whitespaces)
        return candidate.count >= 2 ? candidate : nil
    }

    // MARK: - Side questions to the model (see `PeopleGuard`)

    /// Asks the model which person, if any, a message is about.
    static func nameProbe(for question: String) -> String {
        let asked = question.replacingOccurrences(of: "\n", with: " ")
        return "Question: «\(asked)» Is this question about a specific, named person (not the user, not you)? "
            + "If so, reply with that person's name only. If not, reply NONE."
    }

    /// Asks the model whether a phrase is a person's name. Used when it
    /// named nobody in a message that asks about someone: "Info über Scott
    /// von Gimborn" and a bare "Scott von Gimborn" got NONE, because they
    /// are not questions. In tests it called all 14 names of people names,
    /// and 15 of 16 places, companies, products and dishes not.
    static func personCheckProbe(for candidate: String) -> String {
        "Is «\(candidate)» the name of a person? Answer only yes or no."
    }

    /// The name-like phrase in a message, read from its capitals: two or
    /// more capitalized words in a row, with "von", "van", "de" and the like
    /// between them ("Scott von Gimborn", "Johann Wolfgang von Goethe").
    /// Words that only start a request ("Info", "Wer", "Tell") are not
    /// part of it. Nil when there is none, and for scripts without capitals.
    static func nameCandidate(in text: String) -> String? {
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "-'’"))) }
        var best: [String] = []
        var run: [String] = []
        func close() {
            while let last = run.last, nameParticles.contains(last.lowercased()) { run.removeLast() }
            if run.filter({ !nameParticles.contains($0.lowercased()) }).count >= 2, run.count > best.count { best = run }
            run = []
        }
        for token in tokens {
            let lower = token.lowercased()
            if nameParticles.contains(lower), !run.isEmpty {
                run.append(token)
            } else if let first = token.first, first.isUppercase,
                      token.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" || $0 == "’" }),
                      !requestWords.contains(lower), !nameStopWords.contains(lower) {
                run.append(token)
            } else {
                close()
            }
        }
        close()
        return best.isEmpty ? nil : best.joined(separator: " ")
    }

    /// Capitalized words that open a request rather than belong to a name.
    private static let requestWords: Set<String> = [
        "info", "infos", "information", "informationen", "details", "biografie", "biographie", "lebenslauf",
        "steckbrief", "bio", "biography", "wer", "was", "wie", "who", "what", "tell", "erzähl", "erzähle",
        "kennst", "ist", "war", "sag", "nenne", "qui", "quién", "chi", "quem", "parle-moi", "háblame", "parlami",
    ]

    /// Asks the model whether it knows a person. Always phrased as the
    /// German "Wer ist ...?": in tests that form made the smallest model's
    /// judgement reliable (famous people recognized 17 of 18, private
    /// people flagged 11 of 12), where "Who is ...?" called most private
    /// names known.
    static func identityProbe(for name: String) -> String {
        "Question: «Wer ist \(name)?» Do you know for certain who the person in this question is? Answer only yes or no."
    }

    /// The name in the model's answer to `nameProbe`, if it is one that
    /// appears in the question. The model sometimes answers with a sentence
    /// ("Scott von Gimborn is a fictional character..."); only the leading
    /// words that occur in the question count, which also rules out a
    /// "Yes." or an invented name.
    static func personName(fromProbe output: String, question: String) -> String? {
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first ?? ""
        if line.uppercased().hasPrefix("NONE") { return nil }
        let words = line.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols)) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        for count in stride(from: min(words.count, 6), through: 1, by: -1) {
            let candidate = words.prefix(count).joined(separator: " ")
            guard candidate.count >= 2, question.localizedCaseInsensitiveContains(candidate) else { continue }
            if probeStopWords.contains(candidate.lowercased()) { continue }
            guard let first = candidate.first, first.isUppercase || !first.isCased else { continue }
            return candidate
        }
        return nil
    }

    /// The model's yes or no; nil for anything else.
    static func yesOrNo(_ output: String) -> Bool? {
        let answer = output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .lowercased()
        if answer.hasPrefix("yes") { return true }
        if answer.hasPrefix("no") { return false }
        return nil
    }

    private static let probeStopWords: Set<String> = [
        "yes", "no", "none", "ja", "nein", "ich", "du", "er", "sie", "es", "wir", "ihr", "wer", "was",
        "who", "what", "i", "you", "he", "she", "they", "we", "it", "the", "a", "an", "der", "die", "das",
    ]

    /// Whether the message names the app's developer or the name he
    /// publishes under. The system prompt says who made the app, and the
    /// smallest model still did not connect "Who is Dmitry Mikhaylov?" with
    /// it.
    static func mentionsDeveloper(_ text: String) -> Bool {
        matches(text, [#"\bmikhaylov\b"#, #"\bdealer of happiness\b"#, #"\bdealerofhappiness\b"#])
    }

    /// Apostrophes may be typographic (’): iOS keyboards turn ' into ’,
    /// so the patterns accept both.
    private static func matches(_ text: String, _ patterns: [String]) -> Bool {
        let lower = text.lowercased()
        return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }

    /// Phrases that ask for the time, the date or the day, in the app's
    /// languages. Deliberately phrases rather than single words where a
    /// word alone is common in other senses ("time", "data", the Japanese
    /// and Chinese words for a span of time), and none that is an everyday
    /// word in another of the languages (French "hier" is German "here").
    private static let datePatterns: [String] = [
        // English
        #"\bwhat time\b"#, #"\btime is it\b"#, #"\bcurrent time\b"#, #"\btime now\b"#, #"\bdate\b"#,
        #"\btoday\b"#, #"\btonight\b"#, #"\btomorrow\b"#, #"\byesterday\b"#, #"\bweekday\b"#,
        #"\bday of the week\b"#, #"\b(what|which) day\b"#, #"\b(what|which) (year|month)\b"#,
        #"\b(this|next|last) (week|month|year)\b"#, #"\bhow many days\b"#, #"\bdays (until|till|to|left)\b"#,
        #"\bhow long until\b"#, #"\bo['’]?clock\b"#,
        // German
        #"\bwie spät\b"#, #"\buhrzeit\b"#, #"\bwie viel uhr\b"#, #"\bdatum\b"#, #"\bheute\b"#,
        #"\bmorgen\b"#, #"\bgestern\b"#, #"\bwochentag\b"#, #"\bwelche[rsn]? (tag|jahr|monat)\b"#,
        #"\b(diese|nächste|letzte)[rn]? (woche|monat|jahr)\b"#, #"\bwie viele tage\b"#, #"\btage (bis|noch)\b"#,
        // French
        #"\bquelle heure\b"#, #"\bl['’]heure\b"#, #"\bquel jour\b"#, #"\bquelle date\b"#, #"\baujourd['’]hui\b"#,
        #"\bdemain\b"#, #"\bjour de la semaine\b"#, #"\bquelle année\b"#, #"\bcombien de jours\b"#,
        // Spanish
        #"\bqué hora\b"#, #"\bla hora\b"#, #"\bqué día\b"#, #"\bqué fecha\b"#, #"\bfecha\b"#, #"\bhoy\b"#,
        #"\bmañana\b"#, #"\bayer\b"#, #"\bdía de la semana\b"#, #"\bqué año\b"#, #"\bcuántos días\b"#,
        // Italian
        #"\bche or[ae]\b"#, #"\bche giorno\b"#, #"\bche data\b"#, #"\boggi\b"#, #"\bdomani\b"#, #"\bieri\b"#,
        #"\bgiorno della settimana\b"#, #"\bche anno\b"#, #"\bquanti giorni\b"#,
        // Portuguese
        #"\bque horas\b"#, #"\bque dia\b"#, #"\bque data\b"#, #"\bhoje\b"#, #"\bamanhã\b"#, #"\bontem\b"#,
        #"\bdia da semana\b"#, #"\bque ano\b"#, #"\bquantos dias\b"#,
        // Russian and Ukrainian
        "который час", "сколько времени", "какое (сегодня )?число", "какая дата", "дата", "сегодня", "завтра",
        "вчера", "день недели", "какой (сегодня )?день", "какой (сейчас )?год", "сколько дней",
        "котра година", "скільки часу", "яке (сьогодні )?число", "сьогодні", "вчора",
        "день тижня", "який (сьогодні )?день", "який (зараз )?рік", "скільки днів",
        // Greek
        "τι ώρα", "ημερομηνία", "σήμερα", "αύριο", "χθες", "(ποια|τι) μέρα", "πόσες μέρες",
        // Japanese, Korean, Chinese
        "何時", "日付", "今日", "明日", "昨日", "曜日", "何日", "何年",
        "몇 시", "날짜", "오늘", "내일", "어제", "요일", "며칠", "몇 년",
        "几点", "日期", "今天", "明天", "昨天", "星期几", "周几", "几号", "哪一年", "多少天",
        "幾點", "聽日", "尋日", "星期幾", "禮拜幾", "幾號", "幾多日",
    ]

    /// "Who am I?" and "what do you know about me?" in the app's languages.
    private static let selfPatterns: [String] = [
        #"\bwho am i\b"#, #"\bwhat do you know about me\b"#, #"\babout me\b"#,
        #"\bam i (a|an|the|famous|known|really)\b"#, #"\bwhat (films|movies|books|songs|work) (have|did) i\b"#,
        #"\bwer bin ich\b"#, #"\bwas weißt du (alles )?über mich\b"#, #"\büber mich\b"#,
        #"\bbin ich (ein|eine|der|die|das|bekannt|berühmt|wirklich)\b"#,
        #"\b(welche|was für) \w+ (habe|hab) ich (gemacht|geschrieben|gedreht|gespielt|veröffentlicht)\b"#,
        #"\bqui suis-je\b"#, #"\bque sais-tu (de|sur) moi\b"#,
        #"\bquién soy\b"#, #"\bqué sabes (de|sobre) mí\b"#,
        #"\bchi sono( io)?\b"#, #"\bcosa sai (di|su) me\b"#,
        #"\bquem sou eu\b"#, #"\bo que você sabe sobre mim\b"#,
        "кто я", "что ты (обо мне|знаешь обо мне)", "хто я", "що ти знаєш про мене",
        "ποιος είμαι", "ποια είμαι", "τι ξέρεις για μένα",
        "私は誰", "僕は誰", "私について何を知って", "나는 누구", "내가 누구", "나에 대해 (뭘|무엇을) 알",
        "我是谁", "你对我了解", "你知道我什么", "我係邊個", "你知我啲咩",
    ]

    /// "Tell me", "describe", "explain" and the like, in the app's languages.
    private static let requestPatterns: [String] = [
        #"^\s*(tell|say|give|describe|explain|list|name)\b"#,
        #"^\s*(erzähl|erzähle|sag|sage|nenn|nenne|beschreib|beschreibe|erklär|erkläre)\b"#,
        #"^\s*(raconte|dis|décris|explique)\b"#, #"^\s*(cuéntame|dime|describe|explica)\b"#,
        #"^\s*(raccontami|dimmi|descrivi|spiega)\b"#, #"^\s*(conte|diga|descreva|explique)\b"#,
        #"^\s*(расскажи|скажи|опиши|объясни|розкажи|поясни|πες|περιέγραψε|εξήγησε)"#,
        "教えて", "説明して", "알려", "말해", "告诉", "介绍", "講", "話我知",
    ]

    /// Third-person pronouns, for questions that continue about someone.
    private static let pronounPatterns: [String] = [
        #"\b(er|ihn|ihm|sein|seine|seinen|seinem|seiner|seines|sie|ihr|ihre|ihren|ihrem|ihrer)\b"#,
        #"\b(he|him|his|she|her|hers|they|them|their)\b"#,
        #"\b(il|elle|lui|son|sa|ses|él|ella|su|sus|lei|suo|sua|ele|ela|dele|dela|seu)\b"#,
        #"(^|\s)(он|она|его|её|ее|ему|ей|ним|ней|він|вона|його|її|йому|їй|αυτός|αυτή|αυτόν|αυτήν)(\s|[?.,!]|$)"#,
        "彼", "彼女", "그는", "그녀", "他", "她", "佢",
    ]

    /// "Who is ...?" and "tell me about ..." in the app's languages.
    private static let personPatterns: [String] = [
        #"\bwho (is|was)\b"#, #"\bwho['’]s\b"#, #"\btell me about\b"#, #"\bwhat do you know about\b"#,
        #"\binformation (about|on)\b"#, #"\binfos? (about|on)\b"#, #"\bdetails (about|on)\b"#,
        #"\b(biography|bio) of\b"#,
        #"\bwer (ist|war)\b"#, #"\berzähl(e)? mir (etwas |was )?(über|von)\b"#, #"\bwas weißt du (über|von)\b"#,
        // "Info über Scott von Gimborn" - no question mark, no "wer": the
        // smallest model made the tester an actor with three films.
        #"\binformation(en)? (über|zu)\b"#, #"\binfos? (über|zu|von)\b"#, #"\bdetails (über|zu)\b"#,
        #"\b(biografie|biographie|lebenslauf|steckbrief) (von|über)\b"#, #"\bwas gibt es (über|zu)\b"#,
        #"\bqui (est|était)\b"#, #"\bparle-moi de\b"#, #"\bque sais-tu (de|sur)\b"#,
        #"\binfos? sur\b"#, #"\binformations? sur\b"#, #"\bbiographie de\b"#,
        #"\bquién (es|fue|era)\b"#, #"\bháblame (de|sobre)\b"#, #"\bqué sabes (de|sobre)\b"#,
        #"\binfo(rmación)? sobre\b"#, #"\bbiografía de\b"#,
        #"\bchi (è|era|fu)\b"#, #"\bparlami di\b"#, #"\bcosa sai (di|su)\b"#,
        #"\binfo(rmazioni)? su\b"#, #"\bbiografia di\b"#,
        #"\bquem (é|foi|era)\b"#, #"\bme fale (de|sobre)\b"#, #"\bo que você sabe sobre\b"#,
        #"\binfo(rmações|rmação)? sobre\b"#, #"\bbiografia de\b"#,
        "кто (такой|такая|такие|это|был|была)", "расскажи (мне )?(о|об|про) ", "что ты знаешь (о|об|про) ",
        "информаци[яюи] (о|об|про) ", "биография ",
        "хто (такий|така|такі|це|був|була)", "розкажи (мені )?(про|о) ", "що ти знаєш про ",
        "інформаці[яюї] про ", "біографія ",
        "ποιος (είναι|ήταν)", "ποια (είναι|ήταν)", "πες μου για", "πληροφορίες για", "βιογραφία",
        "は誰", "って誰", "とは誰", "について教えて", "の情報", "のプロフィール", "の経歴",
        "누구(야|예요|에요|인가요|입니까|니)", "에 대해 알려", "에 대한 정보", "의 프로필", "의 경력",
        "谁是", "是谁", "邊個係", "係邊個", "係咩人", "的信息", "的资料", "的简介", "的資料", "的簡介", "嘅資料",
    ]

    // MARK: - The note's wording

    /// "Montag, 26. Oktober 2026 um 11:11" in the answer's language, so the
    /// model can quote it as it is.
    static func dateLine(now: Date, timeZone: TimeZone, language: AppLanguage?) -> String {
        let locale = (language ?? .english).locale ?? Locale(identifier: "en")
        var style = Date.FormatStyle(date: .complete, time: .shortened, locale: locale, timeZone: timeZone)
        style.calendar = Calendar(identifier: .gregorian)
        return now.formatted(style)
    }

    /// The note's sentences in one language, and the two answers the app
    /// gives itself. Written in the language of the answer: a small model
    /// follows a note in its own language best.
    struct Phrases {
        let answerIn: String
        let nowTemplate: String
        /// "Who is ...?" when the model was not asked whether it knows them.
        let unknownPerson: String
        /// "Who is ...?" about someone the model said it does not know.
        let unknownPersonCertain: String
        /// A question that names the developer (not "who is"). He is
        /// "Dmitry Mikhaylov (Dealer Of Happiness)" in the system prompt.
        let developerNote: String
        /// "Who is Dmitry Mikhaylov?"
        let developerAnswer: String
        /// "Who is ...?" about someone the model said it does not know.
        let dontKnowAnswer: String
        /// "Who am I?"
        let aboutUserAnswer: String
        /// Introduces the facts the user asked the app to remember.
        let rememberedIntro: String

        func now(_ date: String) -> String {
            nowTemplate.replacingOccurrences(of: "{date}", with: date)
        }

        /// Which language these phrases are in.
        var language: AppLanguage = .english

        /// The user has given their name. In the note.
        func userIntro(_ name: String) -> String {
            (Self.userIntroTemplates[language] ?? Self.userIntroTemplates[.english] ?? "")
                .replacingOccurrences(of: "{name}", with: name)
        }

        /// The reply to a user who just said their name.
        func greeting(_ name: String) -> String {
            (Self.greetingTemplates[language] ?? Self.greetingTemplates[.english] ?? "")
                .replacingOccurrences(of: "{name}", with: name)
        }

        static let greetingTemplates: [AppLanguage: String] = [
            .english: "Nice to meet you, {name}! How can I help?",
            .german: "Schön, dich kennenzulernen, {name}! Wie kann ich dir helfen?",
            .french: "Enchanté, {name} ! Comment puis-je t'aider ?",
            .spanish: "¡Encantado de conocerte, {name}! ¿En qué puedo ayudarte?",
            .italian: "Piacere di conoscerti, {name}! Come posso aiutarti?",
            .portuguese: "Prazer em te conhecer, {name}! Como posso ajudar?",
            .russian: "Приятно познакомиться, {name}! Чем могу помочь?",
            .ukrainian: "Приємно познайомитися, {name}! Чим можу допомогти?",
            .greek: "Χάρηκα που σε γνώρισα, {name}! Πώς μπορώ να βοηθήσω;",
            .japanese: "{name}さん、はじめまして！何をお手伝いしましょうか？",
            .korean: "{name}님, 만나서 반가워요! 무엇을 도와드릴까요?",
            .mandarin: "{name}，很高兴认识你！有什么可以帮你的吗？",
            .cantonese: "{name}，好高興識到你！有咩可以幫到你？",
        ]

        /// The user's name, said back in "Who am I?".
        func userNameIs(_ name: String) -> String {
            (Self.userNameTemplates[language] ?? Self.userNameTemplates[.english] ?? "")
                .replacingOccurrences(of: "{name}", with: name)
        }

        static let userIntroTemplates: [AppLanguage: String] = [
            .english: "The user says their name is {name}. You know nothing else about them; do not make anything up about them.",
            .german: "Der Nutzer sagt, er heißt {name}. Mehr weißt du nicht über ihn; erfinde nichts über ihn.",
            .french: "L'utilisateur dit s'appeler {name}. Tu ne sais rien d'autre sur lui ; n'invente rien à son sujet.",
            .spanish: "El usuario dice que se llama {name}. No sabes nada más de él; no inventes nada sobre él.",
            .italian: "L'utente dice di chiamarsi {name}. Non sai nient'altro di lui; non inventare nulla su di lui.",
            .portuguese: "O usuário diz que se chama {name}. Você não sabe mais nada sobre ele; não invente nada sobre ele.",
            .russian: "Пользователь говорит, что его зовут {name}. Больше ты о нём ничего не знаешь; ничего о нём не выдумывай.",
            .ukrainian: "Користувач каже, що його звати {name}. Більше ти про нього нічого не знаєш; нічого про нього не вигадуй.",
            .greek: "Ο χρήστης λέει ότι τον λένε {name}. Δεν ξέρεις τίποτα άλλο γι' αυτόν· μην επινοήσεις τίποτα.",
            .japanese: "ユーザーの名前は{name}です。それ以外のことは知りません。何も作り上げないでください。",
            .korean: "사용자의 이름은 {name}입니다. 그 외에는 아무것도 모릅니다. 아무것도 지어내지 마세요.",
            .mandarin: "用户说他叫{name}。除此之外你对他一无所知，不要编造任何内容。",
            .cantonese: "用戶話佢叫{name}。除此之外你對佢一無所知，唔好作任何嘢。",
        ]

        static let userNameTemplates: [AppLanguage: String] = [
            .english: "I only know that your name is {name}.",
            .german: "Ich weiß nur, dass du {name} heißt.",
            .french: "Je sais seulement que tu t'appelles {name}.",
            .spanish: "Solo sé que te llamas {name}.",
            .italian: "So solo che ti chiami {name}.",
            .portuguese: "Só sei que você se chama {name}.",
            .russian: "Я знаю только, что тебя зовут {name}.",
            .ukrainian: "Я знаю лише, що тебе звати {name}.",
            .greek: "Ξέρω μόνο ότι σε λένε {name}.",
            .japanese: "あなたの名前が{name}だということだけは知っています。",
            .korean: "당신의 이름이 {name}이라는 것만 알고 있습니다.",
            .mandarin: "我只知道你叫{name}。",
            .cantonese: "我只知道你叫{name}。",
        ]

        static func `for`(_ language: AppLanguage) -> Phrases {
            var phrases = base(language)
            phrases.language = language == .automatic ? .english : language
            return phrases
        }

        private static func base(_ language: AppLanguage) -> Phrases {
            switch language {
            case .automatic, .english:
                return Phrases(
                    answerIn: "Answer in English.",
                    nowTemplate: "It is now {date}.",
                    unknownPerson: "If you do not know this person for certain, say honestly that you don't know them.",
                    unknownPersonCertain: "You do not know this person. Say honestly that you don't know them, and do not make anything up about them.",
                    developerNote: "Dmitry Mikhaylov, also known as Dealer Of Happiness, is the developer who made you, AiGoodbye. You know nothing else about him. Say exactly that and make nothing up.",
                    developerAnswer: "Dmitry Mikhaylov, also known as Dealer Of Happiness, is the developer who made me, AiGoodbye. I don't have any other information about him.",
                    dontKnowAnswer: "I don't know who that is, and I have no reliable information about this person, so I won't guess. If you tell me more about them, I'm happy to help.",
                    aboutUserAnswer: "I only know what you tell me in this chat. I have no access to your data, your accounts or the internet, so I can't look anything up about you.",
                    rememberedIntro: "You asked me to remember this about you:")
            case .german:
                return Phrases(
                    answerIn: "Antworte auf Deutsch.",
                    nowTemplate: "Es ist jetzt {date}.",
                    unknownPerson: "Wenn du diese Person nicht sicher kennst, sag ehrlich, dass du sie nicht kennst.",
                    unknownPersonCertain: "Du kennst diese Person nicht. Sag ehrlich, dass du sie nicht kennst, und erfinde nichts über sie.",
                    developerNote: "Dmitry Mikhaylov, auch bekannt als Dealer Of Happiness, ist der Entwickler, der dich, AiGoodbye, gemacht hat. Mehr weißt du nicht über ihn. Sag genau das und erfinde nichts.",
                    developerAnswer: "Dmitry Mikhaylov, auch bekannt als Dealer Of Happiness, ist der Entwickler, der mich, AiGoodbye, gemacht hat. Weitere Informationen über ihn habe ich nicht.",
                    dontKnowAnswer: "Ich weiß nicht, wer das ist, und habe keine verlässlichen Informationen über diese Person. Deshalb rate ich lieber nicht. Wenn du mir mehr über sie erzählst, helfe ich gern weiter.",
                    aboutUserAnswer: "Ich weiß über dich nur, was du mir in diesem Chat erzählst. Ich habe keinen Zugriff auf deine Daten, deine Konten oder das Internet und kann deshalb nichts über dich nachschlagen.",
                    rememberedIntro: "Du hast mich gebeten, mir Folgendes über dich zu merken:")
            case .french:
                return Phrases(
                    answerIn: "Réponds en français.",
                    nowTemplate: "Nous sommes le {date}.",
                    unknownPerson: "Si tu ne connais pas cette personne avec certitude, dis honnêtement que tu ne la connais pas.",
                    unknownPersonCertain: "Tu ne connais pas cette personne. Dis honnêtement que tu ne la connais pas et n'invente rien à son sujet.",
                    developerNote: "Dmitry Mikhaylov, aussi connu sous le nom de Dealer Of Happiness, est le développeur qui t'a créé, toi, AiGoodbye. Tu ne sais rien d'autre sur lui. Dis exactement cela et n'invente rien.",
                    developerAnswer: "Dmitry Mikhaylov, aussi connu sous le nom de Dealer Of Happiness, est le développeur qui m'a créé, moi, AiGoodbye. Je n'ai pas d'autres informations sur lui.",
                    dontKnowAnswer: "Je ne sais pas qui c'est et je n'ai pas d'informations fiables sur cette personne, alors je préfère ne pas deviner. Si tu m'en dis plus, je t'aiderai volontiers.",
                    aboutUserAnswer: "Je ne sais de toi que ce que tu me dis dans cette conversation. Je n'ai accès ni à tes données, ni à tes comptes, ni à Internet, donc je ne peux rien chercher sur toi.",
                    rememberedIntro: "Tu m'as demandé de retenir ceci à ton sujet :")
            case .spanish:
                return Phrases(
                    answerIn: "Responde en español.",
                    nowTemplate: "Ahora es {date}.",
                    unknownPerson: "Si no conoces a esta persona con certeza, di honestamente que no la conoces.",
                    unknownPersonCertain: "No conoces a esta persona. Di honestamente que no la conoces y no inventes nada sobre ella.",
                    developerNote: "Dmitry Mikhaylov, también conocido como Dealer Of Happiness, es el desarrollador que te creó a ti, AiGoodbye. No sabes nada más sobre él. Di exactamente eso y no inventes nada.",
                    developerAnswer: "Dmitry Mikhaylov, también conocido como Dealer Of Happiness, es el desarrollador que me creó a mí, AiGoodbye. No tengo más información sobre él.",
                    dontKnowAnswer: "No sé quién es y no tengo información fiable sobre esta persona, así que prefiero no adivinar. Si me cuentas más, te ayudo con gusto.",
                    aboutUserAnswer: "Solo sé de ti lo que me cuentas en este chat. No tengo acceso a tus datos, tus cuentas ni a internet, así que no puedo buscar nada sobre ti.",
                    rememberedIntro: "Me pediste que recordara esto sobre ti:")
            case .italian:
                return Phrases(
                    answerIn: "Rispondi in italiano.",
                    nowTemplate: "Adesso è {date}.",
                    unknownPerson: "Se non conosci questa persona con certezza, di' onestamente che non la conosci.",
                    unknownPersonCertain: "Non conosci questa persona. Di' onestamente che non la conosci e non inventare nulla su di lei.",
                    developerNote: "Dmitry Mikhaylov, noto anche come Dealer Of Happiness, è lo sviluppatore che ha creato te, AiGoodbye. Non sai nient'altro di lui. Di' esattamente questo e non inventare nulla.",
                    developerAnswer: "Dmitry Mikhaylov, noto anche come Dealer Of Happiness, è lo sviluppatore che ha creato me, AiGoodbye. Non ho altre informazioni su di lui.",
                    dontKnowAnswer: "Non so chi sia e non ho informazioni affidabili su questa persona, quindi preferisco non tirare a indovinare. Se mi racconti di più, ti aiuto volentieri.",
                    aboutUserAnswer: "Di te so solo quello che mi dici in questa chat. Non ho accesso ai tuoi dati, ai tuoi account né a internet, quindi non posso cercare nulla su di te.",
                    rememberedIntro: "Mi hai chiesto di ricordare questo su di te:")
            case .portuguese:
                return Phrases(
                    answerIn: "Responda em português do Brasil.",
                    nowTemplate: "Agora é {date}.",
                    unknownPerson: "Se você não conhece essa pessoa com certeza, diga honestamente que não a conhece.",
                    unknownPersonCertain: "Você não conhece essa pessoa. Diga honestamente que não a conhece e não invente nada sobre ela.",
                    developerNote: "Dmitry Mikhaylov, também conhecido como Dealer Of Happiness, é o desenvolvedor que criou você, AiGoodbye. Você não sabe mais nada sobre ele. Diga exatamente isso e não invente nada.",
                    developerAnswer: "Dmitry Mikhaylov, também conhecido como Dealer Of Happiness, é o desenvolvedor que me criou, o AiGoodbye. Não tenho outras informações sobre ele.",
                    dontKnowAnswer: "Não sei quem é e não tenho informações confiáveis sobre essa pessoa, então prefiro não chutar. Se você me contar mais, ajudo com prazer.",
                    aboutUserAnswer: "Só sei de você o que você me conta neste chat. Não tenho acesso aos seus dados, às suas contas nem à internet, então não posso pesquisar nada sobre você.",
                    rememberedIntro: "Você me pediu para lembrar isto sobre você:")
            case .russian:
                return Phrases(
                    answerIn: "Отвечай по-русски.",
                    nowTemplate: "Сейчас {date}.",
                    unknownPerson: "Если ты точно не знаешь этого человека, честно скажи, что не знаешь его.",
                    unknownPersonCertain: "Ты не знаешь этого человека. Честно скажи, что не знаешь его, и ничего о нём не выдумывай.",
                    developerNote: "Dmitry Mikhaylov, также известный как Dealer Of Happiness, — разработчик, который создал тебя, AiGoodbye. Больше ты о нём ничего не знаешь. Скажи именно это и ничего не выдумывай.",
                    developerAnswer: "Dmitry Mikhaylov, также известный как Dealer Of Happiness, — разработчик, который создал меня, AiGoodbye. Другой информации о нём у меня нет.",
                    dontKnowAnswer: "Я не знаю, кто это, и у меня нет надёжных сведений об этом человеке, поэтому гадать не буду. Если расскажешь подробнее, с радостью помогу.",
                    aboutUserAnswer: "Я знаю о тебе только то, что ты рассказываешь мне в этом чате. У меня нет доступа к твоим данным, аккаунтам или интернету, поэтому я ничего не могу о тебе узнать.",
                    rememberedIntro: "Вот что ты просишь меня помнить о тебе:")
            case .ukrainian:
                return Phrases(
                    answerIn: "Відповідай українською.",
                    nowTemplate: "Зараз {date}.",
                    unknownPerson: "Якщо ти точно не знаєш цієї людини, чесно скажи, що не знаєш її.",
                    unknownPersonCertain: "Ти не знаєш цієї людини. Чесно скажи, що не знаєш її, і нічого про неї не вигадуй.",
                    developerNote: "Dmitry Mikhaylov, також відомий як Dealer Of Happiness, — розробник, який створив тебе, AiGoodbye. Більше ти про нього нічого не знаєш. Скажи саме це й нічого не вигадуй.",
                    developerAnswer: "Dmitry Mikhaylov, також відомий як Dealer Of Happiness, — розробник, який створив мене, AiGoodbye. Іншої інформації про нього в мене немає.",
                    dontKnowAnswer: "Я не знаю, хто це, і не маю надійної інформації про цю людину, тож не вгадуватиму. Якщо розкажеш більше, охоче допоможу.",
                    aboutUserAnswer: "Я знаю про тебе лише те, що ти розповідаєш мені в цьому чаті. Я не маю доступу до твоїх даних, облікових записів чи інтернету, тож нічого не можу про тебе дізнатися.",
                    rememberedIntro: "Ось що ти просиш мене пам'ятати про тебе:")
            case .greek:
                return Phrases(
                    answerIn: "Απάντησε στα ελληνικά.",
                    nowTemplate: "Τώρα είναι {date}.",
                    unknownPerson: "Αν δεν γνωρίζεις σίγουρα αυτό το πρόσωπο, πες ειλικρινά ότι δεν το γνωρίζεις.",
                    unknownPersonCertain: "Δεν γνωρίζεις αυτό το πρόσωπο. Πες ειλικρινά ότι δεν το γνωρίζεις και μην επινοήσεις τίποτα γι' αυτό.",
                    developerNote: "Ο Dmitry Mikhaylov, γνωστός και ως Dealer Of Happiness, είναι ο προγραμματιστής που δημιούργησε εσένα, το AiGoodbye. Δεν ξέρεις τίποτα άλλο γι' αυτόν. Πες ακριβώς αυτό και μην επινοήσεις τίποτα.",
                    developerAnswer: "Ο Dmitry Mikhaylov, γνωστός και ως Dealer Of Happiness, είναι ο προγραμματιστής που δημιούργησε εμένα, το AiGoodbye. Δεν έχω άλλες πληροφορίες γι' αυτόν.",
                    dontKnowAnswer: "Δεν ξέρω ποιος είναι και δεν έχω αξιόπιστες πληροφορίες για αυτό το πρόσωπο, οπότε προτιμώ να μη μαντέψω. Αν μου πεις περισσότερα, θα σε βοηθήσω ευχαρίστως.",
                    aboutUserAnswer: "Ξέρω για σένα μόνο όσα μου λες σε αυτή τη συνομιλία. Δεν έχω πρόσβαση στα δεδομένα σου, στους λογαριασμούς σου ή στο διαδίκτυο, οπότε δεν μπορώ να αναζητήσω τίποτα για σένα.",
                    rememberedIntro: "Μου ζήτησες να θυμάμαι τα εξής για σένα:")
            case .japanese:
                return Phrases(
                    answerIn: "日本語で答えてください。",
                    nowTemplate: "現在は{date}です。",
                    unknownPerson: "この人物を確実に知らない場合は、知らないと正直に言ってください。",
                    unknownPersonCertain: "あなたはこの人物を知りません。知らないと正直に言い、この人物について何も作り上げないでください。",
                    developerNote: "Dmitry Mikhaylov（Dealer Of Happinessとしても知られています）は、あなた（AiGoodbye）を作った開発者です。彼についてそれ以上のことは知りません。そのとおりに伝え、何も作り上げないでください。",
                    developerAnswer: "Dmitry Mikhaylov（Dealer Of Happinessとしても知られています）は、私（AiGoodbye）を作った開発者です。彼についてそれ以上の情報はありません。",
                    dontKnowAnswer: "その方が誰なのかわからず、信頼できる情報もないため、推測はしません。もう少し教えていただければ、喜んでお手伝いします。",
                    aboutUserAnswer: "あなたについて私が知っているのは、このチャットで教えてもらったことだけです。あなたのデータやアカウント、インターネットにはアクセスできないため、あなたについて調べることはできません。",
                    rememberedIntro: "覚えておくように頼まれた内容：")
            case .korean:
                return Phrases(
                    answerIn: "한국어로 답하세요.",
                    nowTemplate: "지금은 {date}입니다.",
                    unknownPerson: "이 사람을 확실히 모르면 모른다고 솔직하게 말하세요.",
                    unknownPersonCertain: "당신은 이 사람을 모릅니다. 모른다고 솔직하게 말하고, 이 사람에 대해 아무것도 지어내지 마세요.",
                    developerNote: "Dealer Of Happiness로도 알려진 Dmitry Mikhaylov는 당신(AiGoodbye)을 만든 개발자입니다. 그 외에는 그에 대해 아무것도 모릅니다. 정확히 그렇게 말하고 아무것도 지어내지 마세요.",
                    developerAnswer: "Dealer Of Happiness로도 알려진 Dmitry Mikhaylov는 저(AiGoodbye)를 만든 개발자입니다. 그 외에 그에 대한 정보는 없습니다.",
                    dontKnowAnswer: "누구인지 모르고 이 사람에 대한 믿을 만한 정보도 없어서 추측하지 않겠습니다. 더 알려 주시면 기꺼이 도와드릴게요.",
                    aboutUserAnswer: "저는 이 채팅에서 알려 주신 것만 알고 있습니다. 당신의 데이터나 계정, 인터넷에 접근할 수 없어서 당신에 대해 찾아볼 수 없습니다.",
                    rememberedIntro: "기억해 달라고 요청하신 내용:")
            case .mandarin:
                return Phrases(
                    answerIn: "请用简体中文回答。",
                    nowTemplate: "现在是{date}。",
                    unknownPerson: "如果你不能确定认识这个人，请如实说你不认识。",
                    unknownPersonCertain: "你不认识这个人。请如实说你不认识，不要编造关于这个人的任何内容。",
                    developerNote: "Dmitry Mikhaylov（又名 Dealer Of Happiness）是开发你（AiGoodbye）的开发者。关于他你不知道其他任何信息。请如实这样说，不要编造。",
                    developerAnswer: "Dmitry Mikhaylov（又名 Dealer Of Happiness）是开发我（AiGoodbye）的开发者。关于他，我没有其他信息。",
                    dontKnowAnswer: "我不知道这是谁，也没有关于这个人的可靠信息，所以我不想乱猜。如果你多告诉我一些，我很乐意帮忙。",
                    aboutUserAnswer: "我只知道你在这次聊天中告诉我的内容。我无法访问你的数据、账户或互联网，所以无法查找关于你的任何信息。",
                    rememberedIntro: "你让我记住的关于你的信息：")
            case .cantonese:
                return Phrases(
                    answerIn: "請用廣東話回答。",
                    nowTemplate: "而家係{date}。",
                    unknownPerson: "如果你唔肯定識呢個人，請老實講你唔識。",
                    unknownPersonCertain: "你唔識呢個人。請老實講你唔識，唔好作任何關於佢嘅嘢。",
                    developerNote: "Dmitry Mikhaylov（又叫 Dealer Of Happiness）係開發你（AiGoodbye）嘅開發者。除此之外你唔知道佢任何嘢。請照咁講，唔好作嘢。",
                    developerAnswer: "Dmitry Mikhaylov（又叫 Dealer Of Happiness）係開發我（AiGoodbye）嘅開發者。除此之外，我冇其他關於佢嘅資料。",
                    dontKnowAnswer: "我唔知呢個係邊個，亦冇關於呢個人嘅可靠資料，所以我唔想亂估。如果你講多啲俾我知，我好樂意幫手。",
                    aboutUserAnswer: "我只知道你喺呢個對話入面同我講過嘅嘢。我冇辦法存取你嘅資料、帳戶或者互聯網，所以查唔到關於你嘅任何嘢。",
                    rememberedIntro: "你叫我記住關於你嘅嘢：")
            }
        }
    }
}

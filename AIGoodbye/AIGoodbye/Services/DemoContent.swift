//
//  DemoContent.swift
//  AIGoodbye
//
//  Sample content for App Store screenshots: a few realistic conversations,
//  a folder, a finished recording with its summary, and remembered facts.
//  Debug builds only, and only when launched with AIG_DEMO=1, so it never
//  ships and never touches a real user's data. The screenshot test passes
//  the flag; see AIGoodbyeUITests/AIGoodbyeStoreShots.swift.
//

#if DEBUG
import Foundation

@MainActor
enum DemoContent {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["AIG_DEMO"] == "1"
    }

    /// Stable ids, so a screenshot run can open a specific chat by passing
    /// `-lastConversationId <uuid>` as a launch argument.
    static let sundayId = UUID(uuidString: "D0000000-0000-4000-8000-000000000001")!
    static let japaneseId = UUID(uuidString: "D0000000-0000-4000-8000-000000000002")!
    static let leaseId = UUID(uuidString: "D0000000-0000-4000-8000-000000000003")!
    static let lisbonId = UUID(uuidString: "D0000000-0000-4000-8000-000000000004")!
    static let kyotoId = UUID(uuidString: "D0000000-0000-4000-8000-000000000005")!
    static let interestId = UUID(uuidString: "D0000000-0000-4000-8000-000000000006")!
    static let emailId = UUID(uuidString: "D0000000-0000-4000-8000-000000000007")!
    static let recordingId = UUID(uuidString: "D0000000-0000-4000-8000-000000000010")!

    /// Fills an empty store. Safe to call on every launch: once the sample
    /// conversations exist nothing is added again.
    static func seed(into manager: ConversationManager) {
        guard !manager.conversations.contains(where: { $0.id == sundayId }) else { return }

        let memory = MemoryStore.shared
        memory.add("I'm vegetarian")
        memory.add("My daughter Mia is 7 and loves dinosaurs")
        memory.add("I work as a product manager at a small design studio")

        let travel = manager.createFolder(name: "Travel")

        // Oldest first: the sidebar sorts by recency, so the hero chat ends
        // up at the top.
        add(manager, id: emailId, folder: nil, turns: [
            ("Draft a polite reminder to a client whose invoice is two weeks overdue. Friendly, short.",
             """
             Subject: Quick reminder - invoice #2041

             Hi Laura,

             I hope the new season is off to a good start. Just a gentle nudge that invoice #2041 (sent September 26) is now two weeks past due. If it's already on its way, please ignore this - otherwise, could you let me know when I can expect it?

             Happy to resend the invoice or answer any questions.

             Thanks so much,
             Dmitry
             """)
        ])

        add(manager, id: interestId, folder: nil, turns: [
            ("Explain compound interest like I'm 12.",
             """
             Imagine you put **$100** in a jar that pays you 10% a year.

             - After year 1 you have $110. The jar paid you $10.
             - After year 2 you have **$121**, not $120 - because this time the 10% was counted on $110, including last year's $10.
             - After year 3: $133.10. The extra keeps growing on top of itself.

             That "interest on the interest" is compound interest. It feels slow at first, then it snowballs: at 10% a year, your money roughly **doubles every 7 years** without you adding a cent.

             The catch: it works the same way against you with debt. A credit card charging 20% compounds too.
             """)
        ])

        add(manager, id: kyotoId, folder: travel, turns: [
            ("Packing list for Kyoto in November, 5 days, lots of walking.",
             """
             **Clothes** (days are 10-17°C, evenings colder)
             - Light down jacket or wool coat
             - 2 sweaters, 4 tops, 2 pairs of trousers
             - Comfortable walking shoes you can slip off easily - temples and some restaurants are shoes-off
             - Thin scarf and gloves for evenings

             **Useful**
             - Small daypack, reusable bottle
             - Coin pouch: many shrines and bus fares still use cash
             - Portable battery - you'll be using maps all day
             - Plug adapter (type A, 100 V)

             **Nice to have**
             - Folding umbrella, November has a few rainy days
             - A tote for the Nishiki Market snacks you'll inevitably buy
             """)
        ])

        add(manager, id: lisbonId, folder: travel, turns: [
            ("Three days in Lisbon with a 7-year-old. We like food and being outside.",
             """
             **Day 1 - Alfama and the river**
             Ride tram 28 early, wander Alfama's alleys, lunch at a tasca, then the Oceanário - one of the best aquariums in Europe and a guaranteed hit at seven.

             **Day 2 - Belém**
             Pastéis de Belém for breakfast (yes, before anything else), the Jerónimos cloisters, then scooters or bikes along the riverfront to the Torre de Belém.

             **Day 3 - Sintra**
             Train from Rossio, Pena Palace in the morning before the crowds, picnic in the palace gardens, back to Lisbon for sunset at Miradouro da Senhora do Monte.

             Tip: buy a Viva Viagem card on arrival - it covers trams, metro, and the Sintra train.
             """)
        ])

        add(manager, id: leaseId, folder: nil, turns: [
            ("Summarize the key terms and anything I should watch out for.",
             """
             **Key terms**
             - 12-month lease from **November 1, 2026** at $2,150/month, due on the 1st
             - Security deposit: one month's rent, returned within 21 days of move-out
             - Utilities: tenant pays electricity and internet; water and trash are included
             - One cat allowed with a $300 pet deposit

             **Watch out for**
             - **Section 9**: automatic renewal unless you give 60 days' written notice - set a reminder for **September 1**
             - **Section 14**: a $75 late fee from day 3, which is on the strict side
             - **Section 21**: the landlord may enter with 24 hours' notice "for inspection" with no limit on frequency - worth asking for "reasonable" to be added

             Everything else is standard for this kind of lease.
             """, true)
        ])

        add(manager, id: japaneseId, folder: nil, turns: [
            ("大阪で一日だけ過ごすなら、おすすめの回り方は？",
             """
             一日なら、エリアを絞るのがコツです。

             **午前 - 大阪城**
             開門直後に天守閣へ。天気が良ければ西の丸庭園から城を眺めるのもおすすめです。

             **昼 - 黒門市場**
             市場で食べ歩きランチ。まぐろの串、たこ焼き、季節のフルーツを少しずつ。

             **午後 - なんば・道頓堀**
             グリコの看板、戎橋、そして法善寺横丁の静かな路地でひと休み。

             **夜 - 新世界**
             通天閣をライトアップで見て、串カツで締めくくり。ソースの二度づけは禁止です！

             移動はすべて地下鉄御堂筋線と谷町線で済みます。1日乗車券（エンジョイエコカード）を買っておくと便利です。
             """)
        ])

        add(manager, id: sundayId, folder: nil, turns: [
            ("Plan me a cozy Sunday morning: something to cook, something to read, and one small self-care idea. Keep it short with a nice list.",
             """
             Here's a cozy Sunday morning plan for you:

             **Cook**
             - **Shakshuka for one**: simmer a can of crushed tomatoes with garlic, cumin and a pinch of chili, crack two eggs in, cover for 5 minutes. Crusty bread for dipping.
             - A pot of tea rather than coffee - slower, warmer, no rush.

             **Read**
             - One short story. *The Garden of Forking Paths* by Borges is under 20 pages and perfect for a quiet kitchen table.

             **Self-care**
             - A ten-minute phone-free window: open the window, sit with the tea, and let the morning be a little boring on purpose.

             Enjoy it - and leave the dishes for later.
             """)
        ])

        seedRecording()
    }

    private static func add(
        _ manager: ConversationManager,
        id: UUID,
        folder: Folder?,
        turns: [(String, String, Bool)]
    ) {
        let conversation = manager.createConversation(folderId: folder?.id)
        conversation.id = id
        for (question, answer, hasDocument) in turns {
            _ = manager.addMessage(
                to: conversation,
                role: .user,
                content: question,
                attachmentType: hasDocument ? .document : nil
            )
            _ = manager.addMessage(to: conversation, role: .assistant, content: answer)
        }
        manager.updateConversation(conversation)
    }

    private static func add(
        _ manager: ConversationManager,
        id: UUID,
        folder: Folder?,
        turns: [(String, String)]
    ) {
        add(manager, id: id, folder: folder, turns: turns.map { ($0.0, $0.1, false) })
    }

    private static func seedRecording() {
        let store = RecordingStore.shared
        guard !store.recordings.contains(where: { $0.id == recordingId }) else { return }
        let transcript = """
        Okay, let's get going. Three things today: the onboarding redesign, the pricing page, and the October release. On onboarding, Sara finished the new three-step flow and the test group got through it twice as fast as before, so we're going ahead with it. The copy on step two still reads like a legal notice, Tom will rewrite it by Thursday. Pricing page: we agreed to drop the comparison table and show the three plans as cards, Priya has a draft. We still need the annual discount number from finance. October release: the build is stable, the only open bug is the dark mode contrast on the settings screen. If that's fixed by Wednesday we ship Friday. Last thing, the customer interviews: we have five booked for next week, Mia is sending the guide tonight.
        """
        let summary = """
        ## Summary
        The team approved the new three-step onboarding flow after a test group completed it twice as fast, agreed to replace the pricing comparison table with three plan cards, and confirmed the October release ships Friday if the last open bug is fixed by Wednesday.

        ## Key points
        - Onboarding redesign approved; step-two copy still needs a rewrite
        - Pricing page moves to three plan cards; annual discount figure still missing
        - October build is stable; one open bug (dark mode contrast in Settings)
        - Five customer interviews booked for next week

        ## Action items
        - **Tom**: rewrite onboarding step-two copy by Thursday
        - **Priya**: finish the pricing cards draft; get the annual discount number from finance
        - **Engineering**: fix the dark mode contrast bug by Wednesday
        - **Mia**: send the interview guide tonight
        """
        var recording = Recording(
            id: recordingId,
            title: "Product sync - Thursday",
            duration: 23 * 60 + 41,
            transcript: transcript,
            summary: summary,
            audioFileName: nil,
            languageCode: "en"
        )
        recording.createdAt = Date().addingTimeInterval(-2 * 24 * 3600)
        _ = store.add(recording)
    }
}
#endif

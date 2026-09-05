# App Store copy for AiGoodbye

Paste-ready text for App Store Connect.

## What's New (version 3.1.0, build 12) - the feature release, September 4, 2026

Four big new abilities. All of them 100% private, 100% on your device.

TALK TO YOUR AI
- New voice conversations: tap the waveform button and just talk. Your AI answers out loud, and listening resumes automatically. Works entirely offline - even in airplane mode.

HEY SIRI, ASK AIGOODBYE
- Ask questions through Siri and use AiGoodbye in your Shortcuts automations, including a "Summarize with AiGoodbye" action for any text.

CHAT WITH WHOLE DOCUMENTS
- The new document brain reads your entire PDF or file (up to 300 pages), finds the relevant passages for each question, and remembers the document for the whole conversation.

LIVE CAMERA
- Point your camera at anything and ask about what you see. Answers can be spoken aloud. Nothing is recorded and nothing leaves your device.

PLUS
- All 3.0.1 fixes: faster downloads with real progress, better translations, iPad polish, and dozens of smaller improvements.

Private AI that talks, sees, listens, and reads - with no cloud, no accounts, and no subscriptions.

---

## What's New (version 3.0.1, build 11) - quality release, September 4, 2026

Thanks for the quick feedback on 3.0! This update polishes everything:

DOWNLOADS
- Much faster model downloads with real progress in megabytes (no more stuck "0%")
- Interrupted downloads resume instead of starting over, and a clear warning appears if your connection stalls
- The app now checks free space first and explains clearly if there isn't enough

CHAT
- Fixed the AI occasionally repeating itself in a loop mid-answer
- Apple Intelligence now remembers the conversation when you reopen a chat
- Answers can no longer land in the wrong chat if you switch mid-response

POLISH
- Fixed the model picker in Settings closing unexpectedly
- Fixed several translations that showed English (including the download screen and camera permission)
- Better iPad layouts, larger touch targets, and improved VoiceOver support
- Chats list stays sorted by recent activity; long folder lists now scroll
- Dozens of smaller fixes across storage, files, and settings

As always: 100% private, 100% on-device. Your conversations never leave your device.

---

# Original 3.0.0 copy below. Written August 17, 2026.

## What's New (version 3.0.0)

The biggest update yet. AiGoodbye 3.0 is faster, smarter, and speaks your language.

NEW AI ENGINE
- Answers now stream in live, word by word, with a Stop button
- New Qwen3 Vision model: sharper image understanding and better answers
- NEW Pro model (8B) for iPhone 17 Pro Max class phones: our most powerful AI ever
- Apple Intelligence support: on newer iPhones, chat starts instantly with no download
- A light model option for older iPhones (iPhone 11-13)

BETTER CHAT
- Beautiful formatting: bold text, lists, and code blocks now display properly
- Regenerate, copy, and share any answer
- Clear, honest error messages with one-tap retry

IN YOUR LANGUAGE
- Choose your language right in the app: English, Mandarin, Cantonese, Russian, Ukrainian, Korean, Japanese, French, German, Greek, Italian, Spanish, and Portuguese
- Your choice changes the whole app AND the language the AI answers in, instantly

PICK YOUR LANGUAGE
- New in-app language picker: 13 languages including Cantonese (廣東話), Mandarin, Korean, Ukrainian, and Greek
- Switching changes the whole app and the AI's answers instantly

PLUS
- You choose when to download models (Wi-Fi friendly), and can delete them anytime
- Faster responses in long conversations, especially on older devices
- Dozens of fixes and accessibility improvements

As always: 100% private, 100% on-device. Your conversations never leave your iPhone.

## Description (replaces current, fixes the "Free to use forever" wording)

Your private AI that lives on your iPhone. No cloud. No accounts. No subscriptions.

AiGoodbye runs powerful AI models entirely on your device. Ask questions, analyze photos, and read documents, even in airplane mode. Nothing you type or share ever leaves your phone.

WHY AIGOODBYE
- 100% offline: works without internet after a one-time model download
- 100% private: no servers, no tracking, no data collection (see our App Privacy label: Data Not Collected)
- One-time purchase: no subscriptions, no hidden fees, no accounts
- Vision built in: point it at photos, screenshots, and documents
- 13 languages built in, including Cantonese and Mandarin: pick yours in Settings and both the app and the AI switch instantly

CHOOSE YOUR AI
- Apple Intelligence: instant chat on supported iPhones, zero download
- Qwen3 Vision 2B: our recommended model for image understanding and rich answers
- Qwen3 Vision 8B Pro: maximum intelligence for 12 GB phones (iPhone 17 Pro Max class)
- Smol Vision 500M: light and fast for older iPhones

WHAT PEOPLE USE IT FOR
- Summarizing documents and PDFs privately
- Understanding photos, screenshots, and handwritten notes
- Questions they'd rather not send to a cloud
- AI that works on flights, abroad, and off the grid

Requires about 1-2 GB of free space for a downloaded model (Wi-Fi recommended for the one-time download). Apple Intelligence option requires a supported iPhone with Apple Intelligence enabled.

Say goodbye to subscriptions, data tracking, and cloud dependency. Say hello to AI that is truly yours.

## Submission checklist (in App Store Connect)

Use build 9. (Builds 6, 7, and 8 were superseded; ignore them, or expire them in TestFlight.)

1. Wait for build 3.0.0 (9) to finish processing (email arrives when ready, usually 5-30 minutes)
2. My Apps → AiGoodbye → create version 3.0.0
3. Paste the What's New text above; replace the Description with the new one
4. Select build 9, save
5. Export compliance question: the app only uses standard HTTPS → answer "None of the algorithms mentioned above" (standard exemption)
6. Submit for Review

Build 7 was tested live end to end (chat, streaming, stop, markdown, model switching, consent, settings, storage, persistence, Russian localization) in the iOS Simulator, including real Apple Intelligence responses. A quick TestFlight spin on your physical iPhone is still a nice final touch, mainly to feel the MLX model speed on real hardware, but the app logic itself has been exercised for real.

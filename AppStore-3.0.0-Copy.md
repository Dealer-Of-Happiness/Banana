# App Store copy for AiGoodbye

Paste-ready text for App Store Connect.

## What's New (version 3.4.1, build 17) - September 7, 2026

A fix release for everyone on 3.4.0. If the app wasn't answering, this is the one.

- Fixed: a downloaded model could go unrecognized, so chat waited forever on
  "Preparing" or asked you to download it again. It now loads straight from
  your phone, even on Wi-Fi with no internet
- Fixed: voice conversation and Translate quietly gave up instead of saying
  what went wrong. They now tell you, and let you try again
- Fixed: the recorder could spin at full CPU and then throw away your recording
  with a false "check your microphone" message. The audio is always kept
- Fixed: a crash after a number of photo questions in one conversation
- Fixed: Stop didn't work while a model was still loading
- Model downloads now continue if the app is closed, and pick up where they left off
- Only the microphone permission is asked for; speech is never sent anywhere
- Memory use on 6 GB phones is measured correctly, so the recommended model is offered

100% on device. No cloud, no accounts, no subscriptions.

---

## What's New (version 3.4.0, build 16) - September 6, 2026

A big quality release. Transcription is dramatically more accurate, recordings survive
almost anything, scanning understands the page, and the app is faster and clearer
everywhere.

MUCH BETTER TRANSCRIPTION
- The recorder now uses Apple's newest on-device speech engine, which is far more accurate
  on long recordings - a one-hour meeting has roughly a quarter of the errors it used to
- Add names, product words and jargon the recognizer should get right; they're used for
  every recording and never leave your device
- Automatic punctuation, and no length limit

RECORDINGS THAT SURVIVE THE REAL WORLD
- A recording is saved to disk as it goes, so if the app is ever interrupted, you're
  offered everything captured up to that moment instead of losing it
- Take a phone call mid-meeting and recording resumes by itself afterwards
- AirPods drop out and it reconnects and keeps going, instead of quietly stopping
- Closing the screen mid-recording now asks first, and offers to save
- If transcription ever stops, recording continues and says so - it no longer freezes
  silently for the rest of the meeting

SCANNING THAT UNDERSTANDS THE PAGE
- Scans keep reading order across columns, so two-column documents come out readable
- Tables are recognized as tables and can be copied as a table
- Multi-page scans no longer freeze the app, show real progress, and tell you if any
  page couldn't be read

DESCRIBE SURROUNDINGS, REBUILT AROUND SPEED
- A fast first answer in a fraction of a second, then a fuller description
- One clear sentence by default instead of a paragraph; switch to Detailed when you want more
- In continuous mode it stays quiet when nothing has changed, instead of repeating itself
- A new Repeat button, and it now always answers a deliberate tap out loud rather than
  leaving you in silence
- Better with VoiceOver: the description is readable on a Braille display, and the reason
  it stopped is actually announced

FIRST RUN
- A proper setup screen that tells you what your device needs before you type anything
- Voice, recording and translation are now offered right on the start screen

FIXES AND POLISH
- Fixed Face ID lock, which silently fell back to a passcode
- Photos taken in the app were reaching the AI rotated; they no longer are
- Model downloads continue when you lock your phone, and Stop now really stops one
- Memory use is properly bounded, and a low-memory warning frees the model instead of
  letting the app be killed
- Added Hugging Face models are checked more carefully, and you can add one without
  switching to it
- Clearing a chat now deletes its photos too
- Faster streaming, faster search, and a chat you can scroll while an answer arrives
- Model files and photos are excluded from iCloud backups

100% on device. No cloud, no accounts, no subscriptions.

---

## What's New (version 3.3.0, build 15) - September 5, 2026

Four big new abilities, all of them completely private and completely offline.

PRIVATE RECORDER
- Record meetings, lectures and appointments, with a live transcript written on your device
- Get a summary and a list of action items when you stop, made by the AI on your phone
- Search, rename, play back and export any recording as Markdown or PDF
- Keep the audio or throw it away; either way nothing is uploaded, and recordings are excluded from backups
- Made for the people who legally cannot use cloud transcription

SCAN PAPER
- Scan any document with the camera and the text is read on your device
- Scanned PDFs with no text layer are now read too, so you can ask questions about them

DESCRIBE SURROUNDINGS
- Point the camera and hear what's in front of you, spoken aloud, over and over, hands free
- A Read text mode reads signs, menus and letters back word for word
- Works with no connection at all, so it keeps working on a plane, abroad, or underground

BRING YOUR OWN MODEL
- Add any MLX model from Hugging Face by name and run it on your own phone
- The model is checked before anything downloads: the right files, the size, and whether your device has the memory

ALSO
- Hands-free conversation translation: it listens, translates out loud, then listens again
- Dozens of smaller fixes across audio, memory and storage

100% on device. No cloud, no accounts, no subscriptions.

---

## What's New (version 3.2.0, build 14) - September 5, 2026

AiGoodbye is now everywhere on your device, and it can finally know you - privately.

EVERYWHERE YOU ARE
- Share sheet: send any text, link, PDF or photo from any app straight to AiGoodbye
- Home Screen and Lock Screen widgets for instant chat, voice or camera
- Control Center button to start a private voice conversation in one tap

IT KNOWS YOU (AND ONLY YOU)
- Personas: choose how the AI answers - Editor, Explain Simply, Translator, Code Helper, or write your own
- Memory: tell it "Remember that..." and it will, across every chat, stored only on this device and deletable anytime
- Knowledge Library: keep documents permanently available so the AI can consult them in any conversation

PROOF, NOT PROMISES
- New Privacy Center: a live log of every network request the app makes, an offline test you can run yourself, and a plain-English map of where your data lives
- Lock AiGoodbye with Face ID, Touch ID or your passcode

TRAVEL AND LANGUAGES
- New Translate mode: two-way conversation translation that works with no internet at all, in 13 languages

ALSO NEW
- Search every conversation and message
- Export any chat as Markdown or PDF
- Download models over Wi-Fi only, with downloads that survive a lost connection

Everything here runs on your device. No cloud, no accounts, no subscriptions.

---

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

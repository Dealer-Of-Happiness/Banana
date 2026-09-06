# AiGoodbye — full audit and depth plan

**Date:** 6 September 2026 · **Version audited:** 3.3.0 (build 15, uploaded, not yet submitted)

Three independent audits (services, UI, configuration) plus research into the current
state of on-device speech, OCR, accessibility apps, models and competitors.

The headline: **the four newest features are built on the wrong foundations in three
cases out of four.** Not badly built — built on APIs that were the best available a year
ago and have since been superseded by system frameworks that are faster, more accurate,
free, and already on every user's phone. Fixing that is most of the work below, and it
makes the app better *and* smaller *and* simpler at the same time.

---

## Part 1 — Ship-blockers and near-blockers

These are ordered by what actually hurts a paying user.

### 1. Face ID lock does not work. At all. (critical)

`NSFaceIDUsageDescription` is missing from Info.plist. Without it `LAContext.biometryType`
returns `.none`, so the toggle in Settings that says **"Lock with Face ID"** silently
degrades to a passcode prompt, and biometric evaluation is refused outright.

A privacy feature that is advertised in the UI and does nothing is the worst kind of bug
for this app in particular.

**Fix:** add the key plus 13 translations. Half a day including the localization.

### 2. The KV cache is unbounded — the app can be killed mid-answer (critical)

`GenerateParameters` never sets `maxKVSize` or `kvBits`. `trimHistory` runs once when the
session is built, and the session is then deliberately kept alive across turns, so the
cache grows monotonically for the life of a conversation.

For the 8B Pro model that is roughly **147 KB per token**:

| Context setting | KV cache | Total resident |
|---|---|---|
| 8,192 (default) | ~1.2 GB | ~7 GB |
| 32,768 (slider max) | ~4.8 GB | **~10.6 GB** |

On a 12 GB phone, the second row is a jetsam. And even the first row is exceeded by any
long conversation, because nothing re-trims a live session. The header comment claiming
the context slider "genuinely limits how much history is loaded" is only true of the
first prompt.

This is also the single most-cited complaint about the main competitor, PocketPal: it
stops responding at the context limit instead of evicting.

**Fix:** set `maxKVSize` from the context setting (MLX then uses a rotating cache, which
is what the slider promises), `kvBits: 8` for models ≥ 4 GB, clamp the slider by model
size, and add a memory-warning handler that drops the cache. 3–5 days.

### 3. Every photo taken in-app reaches the vision model rotated 90° (critical)

```swift
if let image, let cgImage = image.cgImage {
    userImage = .ciImage(CIImage(cgImage: cgImage))
}
```

`UIImage.cgImage` is the raw sensor bitmap; `imageOrientation` is discarded. A portrait
iPhone capture has `imageOrientation == .right`. The chat bubble renders it upright
because SwiftUI honours orientation — so the user sees a correct photo and gets a
confused answer, with no clue why. `imageOrientation` appears nowhere in the codebase.

Library images escape only by accident (anything over 1024 px is re-rendered, which bakes
orientation in). Sub-1024 px images, shared images, and the OCR path all have the bug.

**Fix:** one normalisation function at the boundary, used by the VLM, Vision, and the
saved JPEG. Half a day, plus a regression test. This is the app's headline feature.

### 4. There is no first-run experience (critical, commercial)

`ChatEngine.Status.needsSetup` is computed correctly and **rendered nowhere** — the status
chip handles `.downloading` and `.preparing`, and `.ready` and `.needsSetup` both fall
into `default: EmptyView()`.

So on any device without Apple Intelligence, a brand-new paying customer sees: terms wall
→ a chat screen that looks completely ready → they type → *now* a sheet demands a 1.8 GB
download. Nothing before that moment mentions it. And the three quick actions on the
empty state promote chat and attachments — none of the features that justify $9.99.

**Fix:** a real post-terms setup step that detects the engine and either says "you're
ready" or offers the recommended model with size, time estimate and Wi-Fi status. Plus
render `.needsSetup`. 1–1.5 days, and it is probably worth more than any feature in this
document.

### 5. Model downloads die when the phone locks (major)

`ModelPrefetcher` uses `URLSessionConfiguration.default`. A 1–6 GB download — the app's
defining first-run experience — is suspended the moment the user locks the phone or
switches apps. The `audio` background mode does not cover downloads.

**Fix:** `URLSessionConfiguration.background(withIdentifier:)`. About ten lines.

### 6. Three dead ends where the app just stops responding (major)

- **Swiping the consent sheet away** never calls `declineConsent()`, so the "your message
  wasn't answered" banner never appears. The user's first message sits there unanswered.
- **Stopping a model download** swallows the cancellation silently: no answer, no error,
  no banner, and the progress chip vanishes.
- **Voice Mode dismisses itself** the instant a consent request appears — which is
  exactly what should have presented the sheet. Both happen in one transaction, so UIKit
  drops the sheet. The user speaks, and voice mode just closes.

**Fix:** all three collapse into one refactor — replace the nine presentation booleans
with a single `fullScreenCover(item:)` + `sheet(item:)`, and add `onDismiss`. 1 day.

### 7. "Close" during a recording destroys it with no confirmation (major)

The toolbar button reads "Close" while capturing, and `close()` calls `recorder.cancel()`
unconditionally. Forty-five minutes into a deposition, one tap, everything gone.

**Fix:** a confirmation dialog with Stop and Save / Discard / Cancel. An hour.

### 8. Privacy manifest gaps will bounce the next upload (major)

- `ProcessInfo.systemUptime` is used six times in the recorder and is a required-reason
  API. `NSPrivacyAccessedAPICategorySystemBootTime` is not declared → ITMS-91053, which
  Apple has been converting from warning to hard rejection.
- **Neither extension ships a privacy manifest at all**, and both compile `SharedInbox`,
  which uses `UserDefaults` and file timestamps.

**Fix:** three small plist files. An hour.

### 9. Clear Chat leaves the user's photos on disk forever (major)

`clearConversation()` removes messages and document text, then clears
`attachedImageIds` — **without deleting the JPEGs**. `deleteConversation` does delete
them. There is a sweeper for orphaned documents but none for images.

For an app whose pitch is "analyze a photo of your medical result privately", Clear Chat
not deleting the photo is a promise violation.

### 10. Model weights and user photos are in `Documents/` and backed up to iCloud (major)

`DocumentIndex` and `RecordingStore` carefully set `isExcludedFromBackup` and file
protection. Two places do neither: up to 5.8 GB of re-downloadable model weights, and
every photo the user has ever analyzed. The former is a documented App Review rejection
reason (Data Storage Guidelines); the latter contradicts what the Privacy Center implies.

### Also found, briefly

- The user's message **vanishes for several seconds** on any document chat, because
  retrieval runs before the message is persisted and before `isGenerating` is set — during
  which Stop does nothing and switching chats puts the message in the wrong one.
- **Double-tapping Regenerate** deletes two answers and starts two generations.
- **Clear Chat during generation** resurrects a partial answer a second later.
- **Deep links fire while a cover is already up** — a Control Center tap while Voice Mode
  is open is consumed and silently lost.
- `engine.status` does **filesystem I/O on every streamed token**; Manage Storage does
  ~10–15 full recursive directory walks per render; `MarkdownText` re-parses the entire
  answer on every token (O(n²)); chat search rescans every message twice per keystroke.
- **Streaming yanks the scroll view down on every token** — you cannot scroll up to
  re-read the question while an answer streams.
- **VoiceOver reads raw Markdown aloud** ("asterisk asterisk important asterisk asterisk")
  — and the fix already exists in the codebase, unused: `VoiceService.plainSpeech`.
- **The unused llama.cpp package is still linked into the binary** — a whole second
  inference stack with its Metal shaders, plus the only reason `swift-syntax` and the
  CI macro-trust bypass exist.
- **`ITSAppUsesNonExemptEncryption` is missing**, so every upload stalls on export
  compliance.
- **Both extensions are English-only** in a 13-language app.
- The onboarding tagline says **"No internet needed… no data leaving your device"**, which
  is now overstated in both clauses — and it is the first screen an App Review reviewer
  sees, on the app that was already rejected once for exactly this misreading.

---

## Part 2 — Depth: what "best in class" means for each feature

### 2.1 Private recorder

**The finding that matters most in this whole document.**

The recorder uses `SFSpeechRecognizer`. Apple shipped `SpeechAnalyzer` / `SpeechTranscriber`
in iOS 26 — which the app already targets. On independent benchmarks:

| Engine | LibriSpeech test-clean WER | Long-form conversational WER |
|---|---|---|
| **SpeechTranscriber (iOS 26)** | **2.12%** | **14.0** |
| Whisper Small | 3.74% | 12.8 |
| **SFSpeechRecognizer (what we use)** | **9.02%** | — |

An hour-long meeting through the legacy API contains **roughly four times as many wrong
words**. And `SpeechAnalyzer` has **no per-request duration limit** — which means the
entire 45-second segment-rotation mechanism I built (and its two rounds of bugs) exists
solely to work around a limitation of the API we shouldn't be using. Deleting it removes
the most fragile code in the app.

It also brings, free: word-level timestamps, confidence scores, alternative
transcriptions, volatile-vs-finalized results, automatic language detection, and better
noise rejection on distant microphones. The model is system-managed and shared across
apps, so if the user's Notes or Voice Memos already downloaded their locale, it is instant.

The one thing it loses is custom vocabulary — and that is the exact failure mode users
notice most (colleagues' names, product codenames, medical and legal jargon).
`AnalysisContext.contextualStrings` is the replacement lever.

| Work | Effort | Payoff |
|---|---|---|
| **Move to `SpeechTranscriber`**, delete the rotation machinery | 3–4 days | 4× fewer transcription errors; much simpler code |
| **Speaker diarization** — FluidAudio's Pyannote pipeline, ~35 MB, 17.7% DER, 141× real-time | 3–5 days | Turns a wall of text into meeting minutes. Nobody at this price does it on iPhone |
| **Word timestamps → tap-to-seek playback**, word highlighted as it plays | 2–3 days | Reads as premium instantly. Verifying a quote is the #1 thing people do with a transcript |
| **Custom vocabulary** the user maintains, seeded from Contacts with permission | 2 days | Directly attacks the measured weakness. Names being right is what people notice |
| **Two-pass architecture**: live pass for the session, authoritative file pass afterwards in a background task | 3–4 days | Removes the "lost my 2-hour meeting" one-star review |
| **Parakeet v3 as an optional engine** (+15 European languages, better on noisy audio) | 2–3 days | Coverage, and a defensible never-touches-the-network claim |
| **Speaker enrollment** — recognise "Dmitry" across meetings | 1 week | No iPhone competitor does this |

### 2.2 Document scanner

Currently uses `RecognizeTextRequest`, which returns a bag of text lines. iOS 26 has
**`RecognizeDocumentsRequest`**, which returns a structured document tree:

- text grouped by **word / line / paragraph** — i.e. real reading order across columns
- **tables decomposed into cells** with rows and columns
- **lists** decomposed into items, nestable
- barcodes and QR inline
- detected emails, phone numbers, URLs
- per-observation confidence

Switching is **1–2 days** and immediately beats every free scanner on the store. No
competitor I could find uses it.

| Work | Effort | Payoff |
|---|---|---|
| **Switch to `RecognizeDocumentsRequest`** | 1–2 days | Multi-column documents come out readable instead of scrambled |
| **Table extraction → CSV / Markdown** | 2–3 days | A killer demo; Scanner Pro and SwiftScan don't do this on device |
| **Structured receipt/invoice extraction** with guided generation into a typed struct | 3–4 days | Turns a scanner into an expense tool. Highest willingness-to-pay item here |
| **Detected-data action chips** (call, email, open, add to Contacts) | 1 day | Small effort, feels magic |
| **Live capture with quality gating** — reject blur/glare before the OCR pass | 2–3 days | Most "OCR is inaccurate" complaints are actually capture complaints |

### 2.3 Describe Surroundings

The research here is unusually good, and it says the current design has the two most
common failure modes.

A CHI 2024 diary study with 16 blind and low-vision participants over two weeks measured
satisfaction with AI descriptions at **2.76/5** and trust at **2.43/4**. The two findings
that matter:

- **Verbosity is the number one failure.** Apps default to comprehensive descriptions
  regardless of context. Descriptions that instead anticipate the likely question
  answered it **76.1%** of the time and were preferred in head-to-heads.
- **Latency is the other axis.** A 2026 system that speaks a fast coarse answer first and
  fuses in the slower accurate one reached speech **~80% faster** on urgent tasks, and
  **62% of blind participants preferred it to GPT-5**.

Our current implementation waits several seconds in silence for a full VLM pass, then
speaks three to five sentences. That is precisely the pattern the literature says people
turn off within thirty seconds.

| Work | Effort | Payoff |
|---|---|---|
| **Terse by default**, one sentence, "more detail" on demand | 1–2 days | Cheapest high-impact change in this entire document |
| **Two-speed response** — Vision primitives spoken in <300 ms, model description after | 3–5 days | The biggest perceived-quality lever. Latency is what makes these apps "unusable" |
| **Change-triggered speech** in continuous mode — diff and speak only deltas | 2–3 days | The difference between walking around with it and turning it off |
| **Distinct modes**: scan / continuous / find object / read text / currency / product | 1 week | Matches how people actually work; beats the incumbents' one-mode-fits-all |
| **Verbatim text mode, never paraphrased**; currency and barcodes via Vision, never the LLM | 2–3 days | Safety. An LLM paraphrasing a medicine bottle is an incident |
| **Confidence in the voice** — "I think that's…" below threshold, and a real "I'm not sure" | 2 days | Attacks the 2.43/4 trust score directly |
| **VoiceOver-native**: Action button, Back Tap, screen-off operation, barge-in, haptics | 1 week | Nobody in local AI serves this audience |

Note also that our accessibility screen is currently **not usable with VoiceOver on**: it
double-speaks every notice, re-announces the whole growing description on every streamed
token, and puts an enormous text block between the header and the controls.

### 2.4 Bring your own model

The validation flow is solid. What is missing is everything after the download.

| Work | Effort | Payoff |
|---|---|---|
| **Fix long conversations** — sliding window + summarize evicted turns + prompt caching | 3–5 days | Eliminates the category's most-cited complaint (also fixes ship-blocker #2) |
| **Curated catalog with honest per-device fit** — measured tokens/sec, "runs well / runs slowly / won't fit" | 3–4 days | Removes the "which model do I pick" confusion in every competitor's reviews |
| **Prefer QAT / AWQ builds** over naive quantization, and label the method | 2–3 days | Matches Private LLM's main marketing claim, at better quality |
| **Quantized KV cache** (2–4 bit) | 1–2 weeks | Doubles usable conversation length at the same memory |
| **VLM support** so custom models feed the scanner and Describe Surroundings too | 1 week | The cross-feature story nobody else has |

Worth knowing: the model landscape moved. **Gemma 4 E4B** (April 2026) is multimodal
including audio, 128K context, ~30 tok/s on iPhone 17 Pro, ships QAT quantizations — and
is the model Envision independently chose for on-device scene description. **LFM2.5-1.2B**
hits 70 tok/s for instant work. Qwen3-VL-2B remains excellent for documents (92.7 DocVQA).

---

## Part 3 — New features worth adding

Ranked by what only this app could plausibly do.

### 1. Ask across everything (the one nobody has)

The app now holds conversations, recordings with transcripts, scanned documents and a
knowledge library — all on device. **Nothing connects them.** "What did Sarah say about
the budget in last week's meeting?" or "find the invoice I scanned in August" is a
question no competitor can answer at all, because their data is either in the cloud or
in a single-purpose silo.

This is the strongest strategic move available: it turns four features into one product.
**Effort: 1–2 weeks** on top of the existing document index.

### 2. Spotlight indexing

Conversations, recordings, transcripts and library documents are all natural Spotlight
results, all already local, zero privacy cost. Currently zero integration. **2–3 days.**

### 3. Live Activity for the recorder

A four-hour background recording with no Dynamic Island presence is both a UX gap and the
cheapest way to make the background audio mode self-evidently legitimate to a reviewer.
Elapsed time, level, pause and stop. **2–3 days.**

### 4. Real Shortcuts coverage

Two intents exist. Missing: start/stop recording, translate, scan, describe surroundings —
all of which already have deep links — and any `AppEntity` for conversations or
recordings, so none of the content is addressable from Shortcuts. **3–4 days.**

### 5. Provable privacy, not asserted privacy

Every competitor claims local-first; independent reporting has found real gaps between
that marketing and practice. A network kill-switch, a visible byte counter, no analytics
SDK at all, and a published benchmark with raw data is a positioning moat. The Privacy
Center is 80% of the way there already. **3–4 days**, and it is marketing as much as
engineering.

### 6. Publish a benchmark

The closest transcription competitor publishes reproducible WER tables with downloadable
raw transcripts, and it is doing enormous marketing work for them. Roughly a week, and it
buys credibility no App Store screenshot can.

### Smaller, high-value

- **Ratings prompt** — a $9.99 app with no `requestReview` is leaving conversion on the floor.
- **Family Sharing** — a one-time-purchase utility with no server costs; nearly pure upside.
- **iPad**: zero size-class handling anywhere in the codebase. The drawer is a hardcoded
  300 pt, chat bubbles have no max width (~200 characters per line in landscape), and
  multi-window is disabled.
- **Empty conversations accumulate forever** — every "New Chat" tap creates a permanent
  row, and the app always cold-starts on a blank chat regardless of what you were doing.

---

## Part 4 — Suggested sequence

**Week 1 — stop the bleeding.** Face ID key, privacy manifests, export compliance, image
orientation, KV cache bounds, background downloads, the three dead ends, recording
confirmation, Clear Chat image deletion, backup exclusion. Then review notes and the two
copy lines before submitting anything.

**Week 2 — first impressions.** The setup flow, the presentation-layer refactor, streaming
performance (cached download state, memoized Markdown, scroll behaviour), and the
"+" menu / discoverability problem.

**Weeks 3–4 — depth wave one.** `SpeechTranscriber`, `RecognizeDocumentsRequest`, terse-by-
default descriptions, sliding-window context. These four are where the accuracy and
quality jumps live, and three of them also delete code.

**Weeks 5–8 — depth wave two.** Diarization, word timestamps, custom vocabulary, table
extraction, receipt extraction, two-speed descriptions, mode-specific cadences, VoiceOver
work, curated model catalog.

**Then — the differentiators.** Ask-across-everything, Spotlight, Live Activity, full
Shortcuts, published benchmark.

---

*Sources for the research in Part 2: Apple developer documentation for SpeechAnalyzer,
SpeechTranscriber, AnalysisContext, AssetInventory, RecognizeDocumentsRequest and
DataScannerViewController; Argmax and Lyonesse published benchmarks; FluidAudio
documentation; CHI 2024 (arXiv 2403.15604), ICCV 2025 (arXiv 2510.01576) and Audo-Sight
(arXiv 2603.13668) accessibility studies; Gemma 4 and Qwen3.5 model cards; App Store
reviews of PocketPal AI, Private LLM, fullmoon and Lyonesse.*

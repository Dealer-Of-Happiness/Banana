# AIGoodbye: Full App Analysis

Prepared August 17, 2026. Based on a complete read of the shipped v2.0.4 code (plus the merged memory fixes), a review of the App Store listing, and research into the August 2026 on-device model landscape.

## The short version

The app delivers on its core promise: it really is a private, fully offline AI with vision that works, ships, and has a 5.0 rating. The foundation is solid. But it is competing in a fast-moving category with three visible gaps (no streaming text, no markdown rendering, no way to manage models in the UI), one big invisible gap (the model it runs is now two generations old), and a set of small bugs that quietly undermine trust. All of it is fixable, and most of the highest-impact fixes are days, not months, of work.

## What is working well

Honest credit first. The privacy architecture is real: nothing leaves the device and the App Store privacy label says "Data Not Collected," which very few AI apps can claim. Memory handling shows care (images downscaled before inference, history truncation, and now the increased-memory-limit entitlement). The empty chat state with three suggestion cards is genuinely good onboarding. Colors are semantic so dark mode works. The app also runs on iPad and Apple Silicon Macs for free thanks to "Designed for iPad." And the single-model simplification you made in v2.0.4 was a reasonable call at the time: one model that just works beats a confusing picker.

## Issues found

### A. The three visible experience gaps

**1. No streaming.** The answer is generated token by token internally, but the code collects the entire response and shows it all at once (MLXService.swift line 359-371). Users stare at three bouncing dots for up to 30+ seconds, which reads as "frozen." Every competing AI app streams. The plumbing already exists; this is the single highest-impact change in the whole report.

**2. No stop button, and double-sends are possible.** There is no way to cancel a generation in progress, and the send button stays active during generation so a second prompt can pile onto the first.

**3. Markdown renders as raw symbols.** Model output like `**bold**`, lists, and code blocks displays literally, because bubbles use plain `Text` (ChatView.swift line 915). Most structured answers look broken.

### B. Real bugs

The two model-management screens (ModelsSettingsView, ModelSelectionView) exist in code but are unreachable: nothing links to them, so users cannot see, switch, or delete models, and one screen even instructs users to visit a settings entry that does not exist. Generation errors are injected into the chat as normal gray AI bubbles ("Error: ...") and saved to history, where they even get fed back to the model as context; the red error styling in the code is unreachable. Clear Chat has no confirmation, and it does not actually delete saved messages, so a "cleared" chat comes back when you reopen it. Regenerate on a document question re-asks using the label "[Document: name]" instead of the document text, so the second answer is fabricated. Failed photo and document imports print to the console and show the user nothing. And the Context Window slider in Settings (4K-32K) writes a value the AI engine never reads; it is a placebo control.

### C. Trust and consistency issues

The onboarding terms talk about cloud models, external servers, and API keys, while the Settings screens promise "100% offline, no data ever sent." Both texts are maintained as separate hardcoded copies that have already drifted. The App Store description says "No Subscriptions - Free to use forever" on an app that costs $9.99 up front; you mean "no recurring fees," but a skeptical reviewer will call it misleading. The brand is spelled "AIGoodbye" in code and "AiGoodbye" in the UI and store. The first-run experience downloads 1.25 GB immediately after terms acceptance with no size disclosure, Wi-Fi warning, pause, or cancel. And the store listing requires iOS 26.2, English only, with the App Store's new accessibility section left blank.

### D. Code health

About 1,700 lines of dead services ship in the binary (verified count: 1,666) (CloudAI, iCloud sync, knowledge base, voice, image analysis, legacy llama.cpp engine) along with settings machinery for features that have no UI. Prompts are built by hand-concatenating template strings per model family, while the MLX library can apply each model's own chat template automatically; the code even has a cleanup function stripping leaked template tokens out of responses, which is the classic symptom of template mismatch. There are no tests, and the test targets referenced by the project do not exist on disk.

## Better models: yes, meaningfully better

You ship [Qwen2-VL-2B](https://huggingface.co/mlx-community/Qwen2-VL-2B-Instruct-4bit) (4-bit, 1.25 GB), which was a great pick in January. The landscape since then:

| Option | What it is | Why it matters | Fit |
|---|---|---|---|
| [Qwen3-VL 2B / 4B](https://github.com/qwenlm/qwen3-vl) | Direct successor to your model | Big jump in visual perception, OCR, and reasoning; same family so your prompt handling mostly carries over; [supported in MLX Swift](https://github.com/ml-explore/mlx-swift-lm) and praised as the best iPhone VLM by MLX community developers | The default upgrade |
| [Apple Foundation Models](https://developer.apple.com/videos/play/wwdc2026/241/) | Apple's built-in ~3B on-device model, free API in iOS 26, gaining image understanding per WWDC 2026 | Zero download, zero RAM cost for weights you ship, instant availability; only works on Apple Intelligence devices (iPhone 15 Pro and newer) | The hybrid opportunity |
| SmolVLM2-500M | Tiny VLM you already had support for (the template code is still there) | At ~400 MB it fits comfortably on 4 GB devices where a 2B model struggles | The older-device tier |
| [Qwen3.5 small series](https://blog.mean.ceo/qwen-3-5-small-model-series-release/), Gemma 3n, Apple FastVLM, LFM2-VL | Newest wave of small multimodal models | Promising but MLX Swift support needs verification per model (you personally hit "FastVLM not supported" in January) | Watch list |

Two notes. First, the model upgrade requires bumping mlx-swift-lm from your pinned 2.30.3 to the 3.x line, which is a breaking-change migration but also brings a modern session API with cache reuse that helps performance below. Second, my recommended target state is a two-tier catalog plus a hybrid: Qwen3-VL-2B as the standard model, SmolVLM2-500M offered on low-RAM devices, and Apple Foundation Models used for instant text chat on supported devices while the big model downloads in the background. That last one transforms first-run: a new user could be chatting seconds after install.

## Performance on older devices

The iOS 26.2 requirement means the oldest hardware you serve is roughly iPhone 11 through 13, and those are exactly the devices where the current code hurts, for four reasons. First, every single turn rebuilds the entire prompt (up to 60 messages of history) and re-processes it from scratch; there is no reuse of the previous computation, so response delay grows with conversation length and old chips feel it most. The library's newer session API with key-value cache reuse, plus trimming history from 30 pairs to about 8-10, would cut time-to-first-word dramatically. Second, images are sent at up to 1024px, which the vision encoder turns into a very large number of tokens; capping at 768px roughly halves image prefill time with little quality loss on a 2B model. Third, no streaming means all that latency is felt as dead silence (fixing streaming fixes perceived speed everywhere, oldest devices most of all). Fourth, memory: the entitlement we merged raises the ceiling on 6 GB+ devices, but 4 GB devices (iPhone 11, 12, 13 non-Pro) are near the limit with a 2B model plus long history; that is what the small-model tier and shorter history are for. A device-aware default (pick model tier and history length by RAM at first launch) makes all of this automatic. Also worth testing when you next profile: temperature and the 20 MB GPU cache cap are now in place, but a thermal check during long generations on an iPhone 12 would tell us if we need to pace generation.

## UI: yes, it can be tightened considerably

Beyond the three big gaps above, the ranked list: ask consent before the first-run download (size, Wi-Fi note, cancel); stop disguising errors as AI replies and add Retry; give photo and document failures visible feedback; reconnect the model screens once multiple models return; show the conversation title instead of the hardcoded logo text so users know where they are; make the side menu actually follow your finger during the drag (the code tracks the gesture but never moves the view); replace the folder long-press with a standard context menu; add accessibility labels to every icon-only button and grow small tap targets to 44pt (none exist today, and the App Store now displays an accessibility section you could fill honestly after this); adopt a String Catalog and localize, because you ship an 18-language-capable model with an English-only UI and store listing, and languages are one of this app's few unfair advantages; and reconcile the two terms texts into one source of truth.

## Suggested release plan

**Release 2.1, "the feel update" (roughly 1-2 weeks of work):** streaming, stop button plus double-send guard, markdown rendering, real error bubbles with retry, download consent screen, Clear Chat fix and confirmation, import failure alerts, regenerate-with-documents fix, remove or hide the placebo context slider, unify the terms text, fix "Free forever" wording in the store copy. Nothing here risks the model pipeline; it is all UI and glue.

**Release 2.2, "the brain update" (roughly 2-3 weeks, includes the library migration):** mlx-swift-lm 3.x, Qwen3-VL-2B as default with proper library-applied chat templates, session cache reuse, history and image-size tuning, device-aware defaults, SmolVLM2 tier for 4 GB devices, reconnected model management UI, and deletion of the ~1,700 lines of dead services.

**Release 3.0, "the reach update":** Apple Foundation Models hybrid for instant chat on new devices, String Catalog localization starting with your model's strongest languages, App Store accessibility section, refreshed screenshots showing streaming and vision, and a decision on voice (build the missing UI or delete the services).

I can execute any of this on this Mac end to end; each release lands as a PR you approve, and each item is testable on your iPhone before shipping.

## Sources

App Store listing: [AiGoodbye on the App Store](https://apps.apple.com/us/app/aigoodbye/id6757513032). Models and framework: [Qwen3-VL (GitHub)](https://github.com/qwenlm/qwen3-vl), [mlx-swift-lm (GitHub)](https://github.com/ml-explore/mlx-swift-lm), [mlx-community on Hugging Face](https://huggingface.co/mlx-community), [Apple Foundation Models at WWDC26](https://developer.apple.com/videos/play/wwdc2026/241/), [Apple newsroom on Foundation Models](https://www.apple.com/newsroom/2025/09/apples-foundation-models-framework-unlocks-new-intelligent-app-experiences/), [Qwen 3.5 small series](https://blog.mean.ceo/qwen-3-5-small-model-series-release/). Code references are to files in `AIGoodbye/AIGoodbye/` at branch `main`.

# AiGoodbye full app audit — September 4, 2026

Scope: every Swift file in the app (24 files), the string catalog (194 keys × 12 languages), the Xcode project configuration, the privacy manifest, entitlements, assets, and tests. Three independent deep-review passes (engine and data layer; UI and accessibility; configuration and localization integrity), with every high-impact claim re-verified directly against the code before inclusion. Items already fixed in 3.0.1 (frozen download progress, slow downloader, repetition loops, settings picker) are excluded.

The build is in good shape overall: no crash-level defect was found, dark mode is clean, the privacy posture is genuinely strong, and the project settings are largely best-practice. What follows is everything else, ranked by how much it affects real users.

## Fix first (real bugs users will hit)

**1. Dead translations on the most important screen.** Seven entries in the string catalog were stored under hand-written "positional" keys (%1$@/%2$@) that the code never generates at runtime, so their translations exist in all 12 languages but are never found. Verified: the runtime keys are absent from the catalog, the positional twins present. Affected worst: the model download consent sheet — the first screen every non-English user must get through — plus the file import error and two VoiceOver labels. They all silently fall back to English. The fix is renaming the keys to the non-positional form.

**2. Apple Intelligence forgets the whole conversation when you reopen it.** Every conversation open calls resetSessions, which immediately creates a fresh, empty Apple Intelligence session. The send path only seeds past history when no session exists, so the reopened chat's history is never injected: the model answers as if the conversation just started. The MLX (downloaded model) path handles this correctly; the Apple Intelligence path needs the same "drop, then rebuild with history" treatment. On your iPhone 13 Pro Max you'd never see this, but every Apple Intelligence user does.

**3. A stopped or abandoned reply can land in the wrong chat.** If you switch conversations (or tap New Chat) while an answer is generating, the cancelled task still appends its partial text to the chat that is now on screen — a foreign bubble in the wrong conversation until reload. The persistence goes to the right conversation; only the visible transcript is wrong. Needs a guard comparing the conversation the task started in against the one currently shown.

**4. Camera permission prompt is English-only in all languages.** iOS reads permission strings only from a file named InfoPlist.xcstrings, which doesn't exist — the translated strings sit in the main catalog where the system never looks. Creating that file and moving the two entries fixes it.

**5. A killed-mid-download model can look "downloaded" and then quietly break.** The downloaded-check only requires one weights file plus config.json to exist. Kill the app at the wrong moment and the app believes the model is complete: the fast downloader is skipped, and the library quietly re-downloads gigabytes behind a "Preparing…" spinner with no progress UI — or fails cryptically offline. The completeness check should verify file sizes against the download manifest.

**6. No free-space handling for 1.8–5.8 GB downloads.** Nothing checks available disk space before a download, a full-disk error is retried pointlessly and surfaces as a raw system message, and a stranded partial download can't be deleted in the app (the Delete button only appears for complete models). Preflight check, a clear message, and "remove partial download" are needed.

**7. Unbounded file import can freeze or kill the app.** The document flow reads the entire picked file into memory on the main thread with no size cap before trimming to 4,000 characters. A huge .txt from Files will hang or crash the app. (An old DocumentService with a proper 25 MB cap exists but is dead code nothing calls.) The cap needs to move into the live path and the read off the main thread.

**8. Download consent sheet can push its Download button off-screen at large text sizes.** The sheet is a fixed medium-height stack with no scrolling; at accessibility text sizes the primary button becomes unreachable — gating the app's core feature for large-text users. Needs a ScrollView and a large detent.

## Worth fixing soon (correctness and polish)

**Concurrent model loading.** A background warm-up load and a user-triggered load can run at once, loading the model twice — wasteful for small models, a memory-crash risk if it ever happens with the 8B Pro. A simple in-flight-task guard fixes it.

**Switching to Apple Intelligence never frees the downloaded model's RAM.** Selecting the built-in engine after using an MLX model leaves up to ~7 GB resident until iOS kills the app in the background. The engine should unload on switch, and model deletion should also unload.

**Chinese/Japanese/Korean conversations overrun the context budget.** History trimming estimates 3.5 characters per token, but CJK runs 1–1.8 — so the app can feed the model two to three times the intended history in exactly the languages the app now advertises. A script-aware estimate fixes it.

**Failed large downloads restart from zero.** The new downloader retries a failed file from byte zero; a blip at 90% of the 5.8 GB Pro model throws away everything. URLSession resume data would make retries continue where they left off. Also worth adding: a size check after each file lands (the sha256 is available for full verification of weights).

**Silent persistence failures.** Every database save is a try-that-ignores-errors, including total storage initialization failure: the app would run normally while saving nothing. At minimum the initialization failure should surface a visible warning.

**Deleted chats leak their images.** Attachment photos are written to disk but never deleted when their conversation is — unbounded, invisible growth. Deletes should remove the files, plus a launch-time orphan sweep.

**Folder lock weaknesses.** The folder password is stored raw in the Keychain despite a comment claiming a hash; a failed Keychain write can leave a folder locked with no way in; deleting a folder never removes its Keychain entry. Small feature, several sharp edges.

**Regenerate on an older answer appends at the bottom.** Regenerating anything but the last reply produces an out-of-place, out-of-context answer at the end of the chat. Restrict regenerate to the last answer (simplest) or truncate back to the regenerated point.

**Declining a download leaves the message stranded.** Tap "Not Now" on the consent sheet and your sent message just sits there with no way to retry except retyping. A gentle "Try again / choose model" affordance fixes it.

**Settings sliders churn sessions.** Every tick of the Creativity/Memory sliders rebuilds and prewarms sessions — dozens of times per drag. Debounce to the end of the drag.

**Sidebar list ordering goes stale.** Recent chats don't re-sort when a chat gets new messages; folders beyond about eight rows push Settings off-screen with no scrolling. Both are small structural fixes in the side menu.

**Language switch side effects.** Changing language rebuilds the UI (by design) but also closes the Settings sheet abruptly, discards a typed draft and any pending attachment, and hides an in-flight answer. Hoisting that state above the rebuild point preserves it.

## iPad (App Review tested on iPad Air — worth attention)

The app ships to iPad and cannot ever drop iPad support, so it deserves real iPad care: the 300-point overlay menu on an 11-inch screen looks like a phone app stretched (a sidebar split view would look native); confirmation dialogs pop up centered, detached from the buttons that triggered them; the camera sheet letterboxes (should be full screen); terms/about cards stretch edge to edge; and multi-window behavior shares one app state between windows (open the menu in one window, it opens in both) — simplest fix is declaring single-window. Also several user-visible strings say "iPhone" ("Everything stays on your iPhone") — on an iPad that reads as sloppy, and App Review reads it too.

## Accessibility

The closed side menu remains reachable by VoiceOver swipes while invisible, and the open menu doesn't hide the chat behind it; chat rows are plain tap-gestures without button traits; several controls are under the 44-point minimum (banner dismiss, Try Again, code copy button); assembled VoiceOver labels in the model picker are English-only; fixed-size icons don't scale with Dynamic Type. All cheap fixes, and together they move the app from "mostly accessible" to genuinely good.

## Housekeeping (no user impact, quick wins)

A byte-identical 737 KB duplicate of the app icon sits loose in the app folder and ships inside the bundle — delete. Three stale catalog entries carry dead translations; nine language-neutral entries ("4K", "32K", the email address) should be marked do-not-translate to reach a clean 100%. Deployment targets disagree (app 26.0, tests 26.2). The privacy manifest should add reason 3B52.1 for reading timestamps of user-picked files. The .gitignore is a Python template and tracks Xcode user state; an empty leftover local package folder remains; test targets still say version 2.0.0 (cosmetic). Dead code to remove when convenient: DocumentService (replaced inline), two never-used database entities, an unused download-state enum, and the never-written Folder.password field. Chat titles default to a hardcoded English "New Chat" even in the database — localizable at display time.

## What's genuinely solid

No hardcoded-color dark mode breakage; correct safe-area and keyboard behavior; camera and photo usage descriptions present; privacy manifest fundamentally sound; script sandboxing, string catalog symbols, MainActor default isolation, and the increased-memory entitlement all correctly configured; legal text single-sourced between onboarding and About (one drift: it says models are "about 1 to 2 GB", now 5.8 GB for the Pro tier); unit and UI tests in place and green, including the two new 3.0.1 regression tests.

## Suggested sequencing

Batch 1 (ship as 3.0.2 or fold into 3.0.1 if it hasn't been submitted yet): items 1–8 in "Fix first" — all are user-visible, all are contained changes. Batch 2: the "worth fixing soon" list plus accessibility, on a normal cycle with simulator regression tests extended to cover them. Batch 3: the iPad experience as its own themed release (it's the biggest remaining quality gap and also a marketing opportunity: "now feels at home on iPad"). Housekeeping rides along with any batch.

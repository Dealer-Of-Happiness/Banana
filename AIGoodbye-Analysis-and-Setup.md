# AIGoodbye: Project Analysis and Setup Guide

Prepared August 9, 2026. This document explains what is in this folder, what needs fixing, and how to get the project working on this Mac so you can support and improve the app.

## What this project is

AIGoodbye (aigoodbye.ai) is your published iOS app for fully on-device AI. It runs language models directly on the iPhone with two engines: Apple's MLX framework for modern models including vision models (Qwen-VL, SmolVLM), and llama.cpp via the LLM.swift library for older GGUF models. Users download models from Hugging Face inside the app, and everything runs offline. The app also includes conversations stored with SwiftData, iCloud sync, document and image analysis, and voice input.

Key facts:

| Item | Value |
|---|---|
| App name | AIGoodbye |
| Bundle ID | com.aigoodbye.AIGoodbye |
| Apple Developer Team | W7P6DN65A8 (automatic signing) |
| Current version | 2.0.4 (build 5) |
| Built with | Xcode 26.2, iOS 26.0 deployment target |
| Live project | `AIGoodbye/AIGoodbye.xcodeproj` |
| GitHub repo | https://github.com/Dealer-Of-Happiness/Banana (public) |
| Dependencies | mlx-swift, mlx-swift-lm, LLM.swift, swift-transformers (all fetched automatically) |
| CI | Xcode Cloud scripts in `AIGoodbye/ci_scripts/` |

## What is in this folder

The folder is a mono-repo called "Banana" that holds several generations of the project. Only one part matters for the App Store app:

`AIGoodbye/` is the live iOS app, the one published on the App Store. Everything else is history or side projects: `ios/` and `DOHAI/` are two earlier generations of the app (named DOHAI back then), `DOHAI/Banana-claude-offline-ai-with-internet-4BRpa/` is an old downloaded snapshot from a Claude session, `desktop/` is a separate Tauri desktop app, `src/` and the Python files are the original desktop Python prototype, and `docs/` serves the desktop app's update checks. The `Packages/LLMSwift` folder is an empty leftover; the project actually downloads LLM.swift from GitHub, so it can be ignored.

## Three problems found

**1. iCloud has offloaded most file contents.** This folder lives in iCloud Drive, and macOS "optimized storage" has evicted the actual contents of most files to the cloud, leaving placeholders. That is why git commands fail here (the error "Resource deadlock avoided") and why Xcode would fail too. The files are safe in iCloud, they are just not physically on this Mac yet.

**2. The newest code exists only in this folder.** I compared this copy against every branch I could find on GitHub. GitHub's branches top out at version 2.0.0 and 2.0.2. This folder has 2.0.4 build 5, the version actually shipped to the App Store, with edits from February 1, 2026 that appear to have never been pushed. Until this copy is preserved and pushed, it is the only complete copy of your shipped app. Treat it carefully: do not delete this folder, and do not let anything overwrite it with older code from GitHub.

**3. A GitHub access token is stored in plain text.** The file `.git/config` contains your GitHub personal access token embedded in the remote URL (it starts with `ghp_jO7E`). Anyone who obtained that string could push code to your repo as you. The setup steps below remove it and replace it with proper sign-in.

## Setup: step by step

Do these in order. Steps 1 and 2 are the important ones; everything else depends on them.

**Step 1. Download the full folder from iCloud.**
In Finder, open iCloud Drive, right-click the `Banana` folder, and choose "Download Now". Wait until the little cloud icons next to files disappear (it may take a few minutes). This makes every file physically present on this Mac.

**Step 2. Copy the project out of iCloud.**
iCloud Drive is a bad home for a code project: its syncing fights with git and Xcode and causes exactly the kind of file weirdness you have now. Create a folder like `Developer` in your home folder and copy `Banana` there, so you end up with `/Users/dmitry/Developer/Banana`. From now on, work only in that copy. Keep the iCloud copy untouched as a backup until everything below checks out.

**Step 3. Check what git sees.**
Open Terminal, then run:

```
cd ~/Developer/Banana
git status
git log --oneline -5
```

If the Mac offers to install "command line developer tools" first, accept. `git status` will likely show changed files: that is your unpushed 2.0.4 work.

**Step 4. Remove the embedded token and sign in properly.**

```
git remote set-url origin https://github.com/Dealer-Of-Happiness/Banana.git
```

Then go to github.com, Settings, Developer settings, Personal access tokens, and revoke the token starting with `ghp_jO7E`. For day-to-day pushing, the easiest path is signing into GitHub inside Xcode (Xcode, Settings, Accounts, add GitHub account) or installing GitHub Desktop.

**Step 5. Save the 2.0.4 state to GitHub.**

```
git add -A
git commit -m "v2.0.4 as shipped to the App Store"
git checkout -b main
git push -u origin main
```

This creates a clean `main` branch holding exactly what is on the App Store. On the GitHub website, go to the repo Settings and set `main` as the default branch. The old `claude/...` branches then become history you can ignore.

**Step 6. Open the app in Xcode.**
Install Xcode from the Mac App Store if it is not on this Mac yet (you need version 26.2 or newer). Sign in with your Apple Developer Apple ID under Xcode, Settings, Accounts. Then open `~/Developer/Banana/AIGoodbye/AIGoodbye.xcodeproj`. Xcode will spend a few minutes downloading the Swift packages (MLX is large). Then select the AIGoodbye scheme, choose your iPhone or a simulator, and press the Run button.

Two notes for this step. First, test on a real iPhone when possible: the MLX engine needs Apple hardware acceleration and behaves poorly or not at all in the simulator. Second, the project references `AIGoodbyeTests` and `AIGoodbyeUITests` folders that are missing from this copy; if Xcode complains about them, you can create two empty folders with those names next to the `AIGoodbye` folder, or delete those two test targets. They do not affect the app itself.

**Step 7. Confirm the app builds and runs.** Once it runs on your phone, this Mac is fully set up to support the app.

## Working on the app going forward

After setup, the routine for every improvement is: make changes in `~/Developer/Banana` (with Xcode, or by pointing Claude at that folder), test on your phone, commit and push to GitHub, and when ready to ship, bump the version number in Xcode (currently 2.0.4, build 5), then use Product, Archive, Distribute App to send it to App Store Connect. Your Xcode Cloud scripts in `ci_scripts/` can also automate builds from GitHub once the repo's `main` branch is current.

One housekeeping suggestion for later, not urgent: the repo carries a lot of dead weight (DOHAI, ios, the old snapshot folder). Once `main` is safely pushed and building, deleting those folders in a single commit would make the project much easier to navigate, and git keeps their full history anyway.

## Status update, August 17, 2026: setup complete

Everything above has been done. The working project now lives at `~/Developer/Banana` (this iCloud folder is a frozen backup). The shipped v2.0.4 is preserved as the `main` branch on GitHub and set as the default. The full app builds on this Mac, including a successfully code-signed build using the Apple Developer account (team W7P6DN65A8), so the path to device testing and App Store updates is proven. Xcode components installed along the way: iOS 26.5 platform and the Metal Toolchain.

Bonus work: pull request #55 (https://github.com/Dealer-Of-Happiness/Banana/pull/55) contains two build-verified memory fixes recovered from an abandoned branch, awaiting review and merge.

Remaining items: finish the GitHub sign-in inside Xcode (Settings, Source Control, the sheet asks for account `Dealer-Of-Happiness` plus a Personal Access Token generated on GitHub), and delete the old exposed token starting `ghp_jO7E` on the same GitHub page.

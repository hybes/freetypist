# FreeTypist

**FreeTypist** is a fast, 100% local macOS predictive typing, inline autocorrect, and ghost-text autocomplete application powered by on-device Apple Metal inference.

---

## Features

- **System-Wide Inline Ghost Text & Autocorrect**:
  - Real-time inline completions, typo corrections, contraction fixes (`dont` → `don't`, `im` → `I'm`), and `:shortcode` emoji expansions directly at your cursor across macOS apps.
- **100% On-Device Metal Inference**:
  - Runs Qwen 3.5 0.8B, 2B and 4B GGUF models on Apple Silicon Metal GPU, with an instant offline predictor fallback. Older Qwen 2.5 and Llama 3.2 downloads remain available for compatibility.
- **Constant Local Learning & Personalization**:
  - Continuously learns your vocabulary, phrases, and writing style per app.
  - Includes a 1-click **Cotypist Migration** tool to import readable writing history, style preferences, per-app rules and historical stats. Encrypted history requires the installed Cotypist framework and its database key in Keychain.
- **Natural Keyboard Controls**:
  - `Tab`: Accept completion or inline correction.
  - `Option + Tab` (or `` ` ``): Accept next word.
  - `Escape`: Dismiss suggestion.
- **Interactive Playground & Analytics**:
  - Built-in live Playground for testing completions, corrections, slash snippets, and word alternatives, plus local analytics for words and time saved.

---

## Quick Start

Requires an Apple silicon Mac with macOS 14 or later and Swift 6 to build. App packaging downloads the official llama.cpp `b11669` engine, verifies its SHA-256 and bundles its libraries. The portable engine targets macOS 13.3; it avoids accidentally requiring the build machine's OS through Homebrew libraries. Set `LLAMA_SERVER_PATH` to override it with a compatible local build.

Without the engine or a downloaded model, the built-in predictor, spelling corrections and snippets still work. Models download from Hugging Face; inference runs locally. The new Qwen 3.5 GGUFs are from [Unsloth](https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF), based on [Qwen's models](https://huggingface.co/Qwen/Qwen3.5-0.8B).

```bash
# 1. Build the macOS application bundle
make app

# 2. Launch FreeTypist
make run

# (Optional) Install to /Applications
make install
```

On first launch, enable **Accessibility permissions** under **System Settings → Privacy & Security → Accessibility** so FreeTypist can provide inline completions across your macOS apps.

Drag the app icon from the permission step into the Accessibility app list, then enable FreeTypist. The icon refers to the running app, so it adds the right copy. **Show in Finder** and the list's plus button are available if drag and drop is not accepted. If access still fails, remove the old entry and add this copy again, then reopen FreeTypist. Keep one installed copy at a stable path such as `/Applications/FreeTypist.app`.

Local builds use ad-hoc signing by default. Each rebuilt executable has a different permission identity, so macOS may require you to add it again. To preserve the signing identity across builds, supply your existing Apple Development or Developer ID certificate:

```bash
SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" make app
```

Enable emoji shortcuts and emoticons in General settings. In the Playground, select a word to see synonyms; completions and replacements use the current cursor position. Analytics starts empty and records actual activity. Previously saved history and statistics are preserved.

First launch opens Setup: writing defaults, a local model download and real generation test, Accessibility access, then a typing check. Reopen it from **Setup FreeTypist…** in the menu bar or General. It resumes after quitting, including a permission-recovery restart. Basic completions and Playground-only setup are explicit alternatives when a download or permission must wait.

New installations select **Qwen 3.5 2B** on Macs with at least 16 GB RAM, or **Qwen 3.5 0.8B** on smaller Macs. The model is downloaded once and kept outside the app so updates do not download it again. Existing model choices are preserved. Emoji shortcuts default on; optional clipboard and surrounding-window collection default off. Existing preferences are preserved.

FreeTypist detects Cotypist while it is running and offers **Quit Cotypist** in Setup and General. It requests a normal quit and reports a refusal or a pending dialog. To stop Cotypist reopening at login, disable its own **Launch automatically at login** option or use **Manage Login Items…** in General.

**Check sentence spelling when I press Enter** is an optional General setting. At the end of a paragraph, the first unmodified Enter corrects clear spelling mistakes in that paragraph and leaves the text for review. Press Enter again to send or insert a newline. When there are no corrections, Enter behaves normally. Shift–Enter and other modified Enter shortcuts retain their usual behaviour. The check uses the local British English spellchecker, preserves spacing and punctuation, and avoids URLs, code and ambiguous valid words. It is a spelling check, not a grammar rewrite.

Sentence checking requires a readable text field with a verified selection. It skips selected text, mid-line cursors, secure/excluded fields and paragraphs longer than 2,000 UTF-16 units. Inline replacements and sentence corrections verify the exact field, original text, selection and result; if these change, the edit stops. Fields without an Accessibility text setter use individual word replacements for sentence checking, verified from right to left. Other long replacements require an atomic Accessibility write. Unsupported fields show a notice if an attempted replacement cannot be confirmed. No clipboard contents are replaced. Apps determine their own undo and rich-text behaviour; Playground supports undo as one edit.

Run `make test` for the regression suite. The tests use isolated settings and files. `FreeTypist --test-local-engine` waits for the selected model to load and checks a completion; it exits with an error if the engine cannot start.

Set `FREETYPIST_QA_MODEL=/absolute/path/to/model.gguf` when running `make test` to also exercise repeated Tab acceptance with the real local model on a separate loopback port. This checks generated text through the completion engine and editor range logic. Physical global keyboard-hook testing still needs a person typing in the target app.

Local model requests continue an assistant prefill using the bundled [llama.cpp server](https://github.com/ggml-org/llama.cpp/blob/b11669/tools/server/README.md), anchoring generation to the draft instead of opening a chatbot reply. Abbreviation lists are handled as exact shortcuts, not model instructions. Unrelated history and background are excluded from prompts; Playground does not collect external context or train on its own output. Spelling and emoji checks run before model debounce. Window context is collected in a bounded background task, and accepting a global completion requests the next suggestion.

## Downloads and updates

[type.cnnct.uk](https://type.cnnct.uk) serves the download page through Cloudflare Workers. Installers and Sparkle's signed update feed live in the existing MinIO store under `brth/connect-dorset/freetypist/releases`, separate from CNNCT Image. The app offers **Check for Updates…** in its menus and General settings. Sparkle asks about automatic checks; users can change the setting in General.

One-time setup on the signing Mac: run Sparkle's `generate_keys --account com.freetypist.app` and copy its **public** key into `SUPublicEDKey` in `Scripts/Info.plist`. Keep the private key in Keychain. Development builds without a public key leave the updater disabled.

For each release:

1. Increase both version values in `Scripts/Info.plist`, run `make test` and `make app`.
2. On the Mac with the Developer ID certificate, run `SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=your-existing-profile bash Scripts/release_app.sh`. `SPARKLE_TOOLS` can point to Sparkle's `bin` folder on that Mac. This signs, notarises and staples the app and DMG, creates a signed appcast and writes release checksums.
3. Run `node Scripts/publish_release.mjs dist/releases` with the existing authenticated MinIO `mc` alias `brth`. It reads every uploaded installer back to verify the checksum before activating the feed. Published versions cannot be overwritten with different contents.

The signing key and notarisation credentials stay on the signing Mac. Run signing tools in its normal login session (for example Terminal on that Mac); an SSH security session may report a locked keychain even after it was unlocked in the GUI. The publisher needs Node 24+, `mc` and access to the existing bucket. Website changes use `cd website && npm ci && npm test && npm run deploy` with the existing Cloudflare login. To preview, use `npm run dev` in `website`.

## Cotypist feature comparison

Audit of the supplied Cotypist 2026.5 screenshots against FreeTypist's code on 20 October 2026. A saved preference alone does not count as a working feature. System-wide physical keyboard testing remains outstanding.

| Area | FreeTypist status |
| --- | --- |
| Setup | Resumable wizard, real model test and live Accessibility/keyboard-hook checks. Cotypist conflict detection and normal quit request. macOS's built-in text-suggestion setting is not part of the wizard. |
| Core typing | Inline suggestions, spelling fixes, typo suppression, mid-line completion and completion length are implemented and exposed. Optional Enter-to-check paragraph spelling, with a second Enter to send or insert a newline. |
| Model selection | Qwen 3.5 and older Qwen/Llama options. Hardware-based recommendation and verified downloads. Gemma is not yet offered or benchmarked against Qwen. |
| Startup and appearance | Menu-bar app and word count. Launch-at-login is only a saved preference; hiding the menu icon and a separate floating accessory button are missing. |
| Context | Clipboard and accessible window text are implemented, with a combined toggle. Separate controls, screenshot/OCR context and screenshot-based appearance matching are missing. |
| Writing personalisation | Accepted-text learning, global writing instructions, app-specific instructions and searchable/deletable history. Background recording and personalisation strength are wired internally but lack controls. History is local JSON, **not app-encrypted**. |
| Emoji | Shortcodes, emoticons and skin-tone control. Neutral variants are supported internally but lack a control; gender preference is stored without an implementation. The shortcode list is limited. |
| Keyboard shortcuts | Fixed Tab/full, Option–Tab or backtick/word and Escape behaviour. Word spacing/punctuation and Escape policies exist internally. Shortcut recording, configurable bindings and system-wide force-completion/global-toggle shortcuts are missing. |
| Battery | Shorter output and on-demand gating exist internally, but lack settings controls. Automatic smaller-model switching is not implemented. Manual engine sleep and idle sleep are implemented. |
| Per-app settings | Exclusions, tone and custom instructions have controls. Per-app autocorrect, Tab, recording and mid-line restrictions are respected internally/imported but have no controls. Cotypist's per-option inherit/on/off selectors and compatibility mode are missing. |
| Alternatives and synonyms | Basic local alternatives and dictionary synonyms; interactive choices in Playground. Synonym labels exist in the overlay view, but selecting text does not open a usable system-wide picker. System-wide numbered selection and model-based contextual synonyms are missing. |
| Sync | No iCloud writing-history sync or end-to-end encrypted multi-Mac sync. |
| Statistics | Local accepted-word/activity history, app breakdowns and date-range charts. No subscriptions, daily word cap or usage-reporting service. |

Cotypist's [model guidance](https://cotypist.app/pricing) recommends a model the Mac can run smoothly, and its [press kit](https://cotypist.app/press) names Gemma 4 as its default. Google's [Gemma 4 overview](https://ai.google.dev/gemma/docs/core) describes E4B as an efficient on-device model with 4.5B effective parameters (8B total with embeddings). FreeTypist's Qwen 3.5 2B choice prioritises a smaller download and memory use; it is not a claim of better completion quality. A fair recommendation between the two needs the same writing prompts, latency measurements and acceptance-quality review on the target Mac.

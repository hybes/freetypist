# FreeTypist

**FreeTypist** is a fast, 100% local macOS predictive typing, inline autocorrect, and ghost-text autocomplete application powered by on-device Apple Metal inference.

---

## Features

- **System-Wide Inline Ghost Text & Autocorrect**:
  - Real-time inline completions, typo corrections, contraction fixes (`dont` → `don't`, `im` → `I'm`), and `:shortcode` emoji expansions directly at your cursor across macOS apps.
- **100% On-Device Metal Inference**:
  - Automatically recommends and runs local `.gguf` models (`Qwen 2.5`, `Llama 3.2`, `Gemma 4`) on Apple Silicon Metal GPU, plus a zero-latency offline predictor fallback.
- **Constant Local Learning & Personalization**:
  - Continuously learns your vocabulary, phrases, and writing style per app.
  - Includes a 1-click **Cotypist Migration** tool to import existing learned phrases, custom dictionary entries, and historical stats.
- **Natural Keyboard Controls**:
  - `Tab`: Accept completion or inline correction.
  - `Option + Tab` (or `` ` ``): Accept next word.
  - `Escape`: Dismiss suggestion.
- **Interactive Playground & Analytics**:
  - Built-in live Playground for testing completions, corrections, slash snippets, and word alternatives, plus local analytics for words and time saved.

---

## Quick Start

```bash
# 1. Build the macOS application bundle
make app

# 2. Launch FreeTypist
make run

# (Optional) Install to /Applications
make install
```

On first launch, enable **Accessibility permissions** under **System Settings → Privacy & Security → Accessibility** so FreeTypist can provide inline completions across your macOS apps.

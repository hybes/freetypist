import SwiftUI

public struct GhostTextView: View {
    @ObservedObject private var replacementFeedback = ReplacementFeedback.shared
    @ObservedObject var engine = CompletionEngine.shared
    @ObservedObject var settings = AppSettings.shared

    public init() {}

    private var effectiveFontSize: CGFloat {
        let base = GhostOverlayPanel.shared.detectedFontSize
        return min(max(base + CGFloat(settings.ghostFontSizeOffset), 11), 22)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let message = replacementFeedback.message {
                Text(message)
                    .font(.system(size: effectiveFontSize))
                    .padding(5)
                    .background(Color(nsColor: .textBackgroundColor))
            } else if let typo = engine.activeAutocorrect {
                // Inline Autocorrect Strikethrough Red + Correction Green
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(typo.misspelledWord)
                        .font(.system(size: effectiveFontSize, weight: .regular))
                        .strikethrough(true, color: .red)
                        .foregroundColor(.red.opacity(0.85))

                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)

                    Text(typo.correctedWord.trimmingCharacters(in: .whitespaces))
                        .font(.system(size: effectiveFontSize, weight: .semibold))
                        .foregroundColor(.green)

                    if settings.showShortcutBadges {
                        badgeView(label: "⇥", subtitle: "fix")
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.green.opacity(0.35), lineWidth: 0.7)
                )
            } else if !engine.activeEmojiCandidates.isEmpty {
                // Compact Emoji Shortcode Picker at Cursor
                HStack(spacing: 5) {
                    ForEach(engine.activeEmojiCandidates.prefix(5)) { cand in
                        HStack(spacing: 3) {
                            Text(cand.emoji)
                                .font(.system(size: effectiveFontSize + 1))
                            Text(cand.shortcode)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(cand == engine.activeEmojiCandidates.first ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
            } else if let suggestion = engine.currentSuggestion, !suggestion.remainingText.isEmpty {
                if settings.showShortcutBadges {
                    // Optional HUD pill style when user explicitly enables shortcut badges
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(suggestion.remainingText)
                            .font(.system(size: effectiveFontSize, weight: .regular))
                            .foregroundColor(settings.ghostTextColorPreset.swiftUIColor.opacity(settings.ghostTextOpacity))
                            .lineLimit(2)
                            .truncationMode(.tail)

                        HStack(spacing: 4) {
                            badgeView(label: "⇥", subtitle: "all")
                            badgeView(label: "⌥⇥", subtitle: "word")
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
                    .fixedSize(horizontal: true, vertical: true)
                } else {
                    // Default Cotypist-style pure inline ghost text directly inside the input at the cursor
                    Text(suggestion.remainingText)
                        .font(.system(size: effectiveFontSize, weight: .regular, design: .default))
                        .foregroundColor(settings.ghostTextColorPreset.swiftUIColor.opacity(settings.ghostTextOpacity))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(0)
                        .background(Color.clear)
                        .fixedSize(horizontal: true, vertical: true)
                }
            }

            // Contextual Synonyms Picker (when text is selected)
            if !engine.activeSynonyms.isEmpty {
                HStack(spacing: 5) {
                    ForEach(engine.activeSynonyms.prefix(5)) { syn in
                        HStack(spacing: 2) {
                            Text("\(syn.index)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(.accentColor)
                            Text(syn.text)
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
            }
        }
    }

    private func badgeView(label: String, subtitle: String) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 8, weight: .regular))
                    .foregroundColor(.secondary.opacity(0.8))
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }
}

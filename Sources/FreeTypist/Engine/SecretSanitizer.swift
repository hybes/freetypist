import Foundation

/// Replicates Cotypist's SecretSanitizer to ensure passwords, API keys, tokens,
/// private keys, IBANs, and credentials are never recorded into typing history
/// or sent to prompts.
public struct SecretSanitizer: Sendable {
    private static let patterns: [(name: String, regex: NSRegularExpression)] = {
        let rawPatterns: [(String, String)] = [
            ("Private Key", "-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"),
            ("AWS Key", "\\b(?:AKIA|ASIA)[0-9A-Z]{16}\\b"),
            ("Stripe Key", "\\b(?:sk|rk)_(?:live|test)_[0-9A-Za-z]{16,}\\b"),
            ("OpenAI Key", "\\bsk-(?:proj-)?[0-9A-Za-z_-]{20,}\\b"),
            ("GitHub Token", "\\bgh[pousr]_[0-9A-Za-z]{20,}\\b"),
            ("Google API Key", "\\bAIza[0-9A-Za-z_-]{35}\\b"),
            ("Slack Token", "\\bxox[baprs]-[0-9A-Za-z-]{10,}\\b"),
            ("JWT Token", "\\beyJ[0-9A-Za-z_-]{8,}\\.[0-9A-Za-z_-]{8,}\\.[0-9A-Za-z_-]{8,}\\b"),
            ("URL Credentials", "[A-Za-z][A-Za-z0-9+.\\-]*://[^\\s/:@]+:[^\\s/@]+@"),
            ("Password Assignment", "(?i)(\\b(?:pass(?:word|wort|wd|phrase)|kennwort|secret|api[_-]?key|access[_-]?key|private[_-]?key|client[_-]?secret|authorization)[ \\t]*[:=][ \\t]*)(\\S+)"),
            ("Shell Export Secret", "(?m)^([ \\t]*(?:export[ \\t]+)?[A-Z][A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASS|PWD|AUTH)[A-Z0-9_]*[ \\t]*=[ \\t]*)(\\S+)")
        ]
        return rawPatterns.compactMap { name, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
            return (name, regex)
        }
    }()

    public static func sanitize(_ input: String) -> (sanitized: String, redactedTypes: [String]) {
        guard !input.isEmpty else { return (input, []) }
        var result = input
        var detected: [String] = []

        for (name, regex) in patterns {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            if regex.firstMatch(in: result, options: [], range: range) != nil {
                detected.append(name)
                if name == "Password Assignment" || name == "Shell Export Secret" {
                    result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1[REDACTED]")
                } else {
                    result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "[REDACTED]")
                }
            }
        }
        return (result, detected)
    }

    public static func containsSecrets(_ input: String) -> Bool {
        let (_, detected) = sanitize(input)
        return !detected.isEmpty
    }
}

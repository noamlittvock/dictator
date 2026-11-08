import Foundation

/// Replaces credentials that commonly end up pasted into prompts — API keys,
/// tokens, private keys, passwords in URLs — with `[redacted]` before a
/// prompt is stored. On by default (Settings → Prompts → Privacy).
enum SecretScrubber {
    private static let patterns: [NSRegularExpression] = [
        // Private key blocks.
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
        // Provider keys: OpenAI / Anthropic / OpenRouter / Groq / xAI …
        #"\b(?:sk|rk|pk)-(?:[A-Za-z0-9]+-)*[A-Za-z0-9_\-]{20,}"#,
        #"\bgsk_[A-Za-z0-9]{20,}"#,
        #"\bxai-[A-Za-z0-9]{20,}"#,
        // GitHub, GitLab, Slack, Google, AWS, Stripe, Hugging Face.
        #"\bgh[pousr]_[A-Za-z0-9]{30,}"#,
        #"\bgithub_pat_[A-Za-z0-9_]{40,}"#,
        #"\bglpat-[A-Za-z0-9_\-]{20,}"#,
        #"\bxox[abposr]-[A-Za-z0-9-]{10,}"#,
        #"\bAIza[0-9A-Za-z_\-]{35}"#,
        #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#,
        #"\b(?:sk|rk)_(?:live|test)_[0-9A-Za-z]{20,}"#,
        #"\bhf_[A-Za-z0-9]{30,}"#,
        // JWTs.
        #"\beyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#,
        // Bearer tokens.
        #"(?i)\bbearer\s+[A-Za-z0-9_\-\.=]{20,}"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// `password=…`, `api_key: …`, `"secret": "…"`, `AWS_SECRET_ACCESS_KEY=…` —
    /// keep the name, hide the value. The name may have words around it; a
    /// quoted value runs to its closing quote, spaces and all.
    private static let assignment = try! NSRegularExpression(
        pattern: #"(?i)(?<![a-z0-9_\-])((?:[a-z0-9]{1,32}[_\-]){0,6}(?:password|passwd|pwd|secret|api[_\-]?key|access[_\-]?key|private[_\-]?key|(?:access|auth|refresh|id)[_\-]?token)(?:[_\-][a-z0-9]{1,32}){0,6}["']?\s*[:=]\s*)(?:"[^"\n]+"|'[^'\n]+'|[^\s"',;]{6,})"#
    )

    /// `scheme://user:password@host`. Each part is bounded: unbounded, a long
    /// hyphenated word rescans from every boundary and takes a minute.
    private static let urlCredential = try! NSRegularExpression(
        pattern: #"(?i)\b([a-z][a-z0-9+.\-]{0,31}://[^/\s:@]{1,256}:)([^/\s@]{1,512})(@)"#
    )

    static func scrub(_ text: String) -> String {
        var result = text
        for pattern in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: "[redacted]")
        }
        var range = NSRange(result.startIndex..., in: result)
        result = assignment.stringByReplacingMatches(in: result, range: range, withTemplate: "$1[redacted]")
        range = NSRange(result.startIndex..., in: result)
        result = urlCredential.stringByReplacingMatches(in: result, range: range, withTemplate: "$1[redacted]$3")
        return result
    }
}

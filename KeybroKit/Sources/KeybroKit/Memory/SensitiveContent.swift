import Foundation

/// Content that must never be stored in memory. Checked on the text itself and on the
/// window title, so searches on adult sites and typing in those tabs are skipped too.
///
/// Keyword based, local and instant. Whole words only, so "Sussex", "cocktail" or
/// "analysis" don't trip it. It won't catch everything; the nightly job can add a model check later.
public enum SensitiveContent {
    private static let sexualTerms = [
        // English
        "sex", "sexy", "sexual", "sexually", "sexting", "sext", "sexts", "porn", "porno", "pornography", "nsfw",
        "nude", "nudes", "naked", "horny", "boobs", "boobies", "tits", "titties", "dick", "dicks", "cock", "cocks",
        "pussy", "blowjob", "blowjobs", "handjob", "handjobs", "orgasm", "orgasms", "masturbate", "masturbating",
        "masturbation", "erotic", "erotica", "fetish", "fetishes", "bdsm", "hentai", "milf", "dildo", "dildos",
        "vibrator", "threesome", "hookup", "hookups", "escort", "escorts", "stripper", "camgirl", "camgirls",
        "cumshot", "creampie", "anal", "deepthroat", "jerk off", "jerking off", "one night stand",
        // Obfuscated spellings
        "s3x", "s3xy", "p0rn", "pr0n", "n00ds", "nud3s", "seggs",
        // Hinglish
        "chudai", "chut", "choot", "lund", "bhabhi sex", "sexy video", "bf video", "blue film",
        // Adult sites
        "pornhub", "xvideos", "xnxx", "xhamster", "onlyfans", "chaturbate", "redtube", "youporn", "spankbang",
        "brazzers", "stripchat", "fansly",
    ]

    private static let pattern: NSRegularExpression = {
        let alternatives = sexualTerms
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: "\\s+") }
            .joined(separator: "|")
        // Letters/digits must not touch the match on either side (so "Sussex" and "cocktail" pass).
        return try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])(?:\(alternatives))(?![\\p{L}\\p{N}])", options: [.caseInsensitive])
    }()

    public static func isSexual(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        let folded = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        return pattern.firstMatch(in: folded, range: NSRange(location: 0, length: (folded as NSString).length)) != nil
    }

    /// True if anything about this text or where it was typed shouldn't be remembered.
    public static func shouldSkip(text: String?, windowTitle: String?, contact: String? = nil) -> Bool {
        isSexual(text) || isSexual(windowTitle) || isSexual(contact)
    }
}

// SponsorDetection — owner: Module D (PLAN.md §6.5 on-device sponsor detection; `suggestedSegments`, §5.4).
//
// Pure pieces of on-device sponsor detection. The app target's SponsorDetector runs Apple's
// on-device model (FoundationModels, which Core must not import) over what this file prepares:
//   1. `chunks`: transcript cues grouped into windows that fit the model's context, overlapping
//      by about 20 s so an ad read at a window edge is seen whole by one of them;
//   2. `prefilterMatches`: a chunk goes to the model only if it contains a sponsor-ish phrase;
//   3. `instructions` + `prompt(for:)` + `segmentSchema`: what the model is asked and how it must
//      answer (the app builds a DynamicGenerationSchema from `segmentSchema`: no @Generable,
//      whose macro plugin isn't available on Linux);
//   4. `segments(fromModelJSON:chunk:options:)`: validates the answer, snaps it to cue
//      boundaries; `merge` joins the chunks' answers.
// Detections are only *suggestions*: sponsorblock.js shows them and never auto-skips them.

import Foundation

public enum SponsorDetection {
    // MARK: Chunks

    /// A window of the transcript, rendered for the model.
    public struct Chunk: Equatable, Sendable {
        public var cues: [Captions.Cue]
        public var start: Double { cues.first?.start ?? 0 }
        public var end: Double { cues.last?.end ?? 0 }
        /// One line per cue: `[66] first paying some bills …` (whole seconds, rounded down).
        public var text: String { cues.map(SponsorDetection.line).joined(separator: "\n") }

        public init(cues: [Captions.Cue]) {
            self.cues = cues
        }
    }

    /// About 1,500 tokens of transcript (≈ 4 chars/token), leaving room in a 4,096-token context
    /// for the instructions, the schema and the answer.
    public static let defaultChunkCharacters = 6_000
    public static let defaultOverlapSeconds = 20.0

    static func line(_ cue: Captions.Cue) -> String {
        "[\(label(cue.start))] \(cue.text)"
    }

    /// The whole-second label a line is shown with (and that the model answers in).
    static func label(_ seconds: Double) -> Int {
        Int(seconds.rounded(.down))
    }

    /// Consecutive windows of at most `maxCharacters` rendered characters (a single longer cue
    /// gets a window of its own). Each window after the first starts at the earliest cue that
    /// begins within `overlapSeconds` before the previous window's last cue ended, and always
    /// after the previous window's first cue, so the loop always advances.
    public static func chunks(_ cues: [Captions.Cue], maxCharacters: Int = defaultChunkCharacters,
                              overlapSeconds: Double = defaultOverlapSeconds) -> [Chunk] {
        var out: [Chunk] = []
        var i = 0
        while i < cues.count {
            var j = i
            var characters = 0
            while j < cues.count {
                let length = line(cues[j]).count + 1
                if j > i, characters + length > maxCharacters { break }
                characters += length
                j += 1
            }
            out.append(Chunk(cues: Array(cues[i..<j])))
            guard j < cues.count else { break }
            let overlapFrom = cues[j - 1].end - overlapSeconds
            var k = j
            while k - 1 > i, cues[k - 1].start >= overlapFrom { k -= 1 }
            i = k
        }
        return out
    }

    // MARK: Prefilter

    /// A sponsor-ish phrase: a case-insensitive regular expression over the chunk's text (cue
    /// texts joined by single spaces, so a phrase split across lines still matches).
    public struct Keyword: Sendable {
        public var pattern: String
        public var note: String
    }

    /// Generous on purpose: the model decides. Each entry says why it is here.
    public static let keywords: [Keyword] = [
        // Disclosure wording.
        Keyword(pattern: #"\bsponsor"#, note: "sponsor, sponsored, sponsoring, sponsorship"),
        Keyword(pattern: #"\bbrought to you by\b"#, note: "\"today's video is brought to you by …\""),
        Keyword(pattern: #"\bthanks? (you )?to [\w .'&-]{1,40}? for\b"#, note: "\"thanks to X for sponsoring / supporting …\""),
        Keyword(pattern: #"\bpartner(ed|ing)? with\b"#, note: "\"we partnered with …\""),
        Keyword(pattern: #"\bpaid (promotion|partnership)\b"#, note: "YouTube's own disclosure wording"),
        Keyword(pattern: #"\bpaying (some|the) bills\b"#, note: "\"but first, paying some bills\" (fixture WWfjoGZmrTo, 66 s)"),
        Keyword(pattern: #"\b(word|message) from (our|today's|this video's) sponsor"#, note: "\"a quick word from our sponsor\""),
        Keyword(pattern: #"\bmade possible by\b"#, note: "\"this video is made possible by …\""),
        Keyword(pattern: #"\bsupport(s|ing)? (the|this) channel\b"#, note: "\"… supports the channel\""),
        // Calls to action.
        Keyword(pattern: #"\b(use|enter|with) (the |my )?code\b"#, note: "\"use code X\""),
        Keyword(pattern: #"\b(promo|discount|coupon) code\b"#, note: "\"promo code\""),
        Keyword(pattern: #"\blinks? (is |are )?(down )?(in|below) (the|my) description\b"#, note: "\"link in the description\""),
        Keyword(pattern: #"\b(link|links) below\b"#, note: "\"link below\""),
        Keyword(pattern: #"\bdescription below\b"#, note: "\"… in the description below\""),
        Keyword(pattern: #"\d+ ?(%|percent) off\b"#, note: "\"20% off\" / \"20 percent off\""),
        Keyword(pattern: #"\bfree trial\b"#, note: "\"start your free trial\""),
        Keyword(pattern: #"\bcheck (them |it )?out\b"#, note: "\"check out X\" (very common; the model filters)"),
        Keyword(pattern: #"\bsign up\b"#, note: "\"sign up at …\""),
        Keyword(pattern: #"\b(dot com|\.com) ?(slash|/)"#, note: "\"X dot com slash Y\" vanity URLs"),
        Keyword(pattern: #"\bfirst \d+ (people|users|customers)\b"#, note: "\"the first 1,000 people …\""),
        // Frequent sponsors (SponsorBlock's most common brands).
        Keyword(pattern: #"\bnord ?vpn\b"#, note: "NordVPN"),
        Keyword(pattern: #"\bexpress ?vpn\b"#, note: "ExpressVPN"),
        Keyword(pattern: #"\bsurfshark\b"#, note: "Surfshark"),
        Keyword(pattern: #"\bsquare ?space\b"#, note: "Squarespace"),
        Keyword(pattern: #"\bbrilliant\b"#, note: "Brilliant.org (also an ordinary word)"),
        Keyword(pattern: #"\braid(:)? shadow legends\b"#, note: "RAID: Shadow Legends"),
        Keyword(pattern: #"\bhoney\b"#, note: "Honey (also an ordinary word)"),
        Keyword(pattern: #"\baudible\b"#, note: "Audible"),
        Keyword(pattern: #"\bskill ?share\b"#, note: "Skillshare"),
        Keyword(pattern: #"\bathletic greens\b|\bag ?1\b"#, note: "Athletic Greens / AG1"),
        Keyword(pattern: #"\bhello ?fresh\b"#, note: "HelloFresh"),
        Keyword(pattern: #"\bmanscaped\b"#, note: "Manscaped"),
        Keyword(pattern: #"\bbetter ?help\b"#, note: "BetterHelp"),
        Keyword(pattern: #"\bdashlane\b"#, note: "Dashlane"),
        Keyword(pattern: #"\bincogni\b"#, note: "Incogni"),
        Keyword(pattern: #"\bshopify\b"#, note: "Shopify"),
        Keyword(pattern: #"\bcuriosity ?stream\b|\bnebula\b"#, note: "CuriosityStream / Nebula"),
        Keyword(pattern: #"\bmint mobile\b"#, note: "Mint Mobile"),
        Keyword(pattern: #"\bgrammarly\b"#, note: "Grammarly"),
        Keyword(pattern: #"\bfactor ?75?\b|\bfactor meals\b"#, note: "Factor"),
        Keyword(pattern: #"\bray ?con\b"#, note: "Raycon"),
        Keyword(pattern: #"\bopera gx\b"#, note: "Opera GX"),
        Keyword(pattern: #"\bkeeps\b|\bhims\b"#, note: "Keeps / Hims"),
        Keyword(pattern: #"\bpatreon\b"#, note: "Patreon (self-promotion)"),
        Keyword(pattern: #"\bmerch\b"#, note: "merchandise (self-promotion)"),
    ]

    /// The chunk's text as the prefilter sees it: lowercase cue texts joined by single spaces.
    static func searchText(_ chunk: Chunk) -> String {
        chunk.cues.map(\.text).joined(separator: " ").lowercased()
    }

    /// The notes of the keywords the chunk matches (empty → don't ask the model).
    public static func prefilterMatches(_ chunk: Chunk) -> [String] {
        let text = searchText(chunk)
        let range = NSRange(text.startIndex..., in: text)
        return keywords.compactMap { keyword in
            guard let regex = try? NSRegularExpression(pattern: keyword.pattern, options: [.caseInsensitive]),
                  regex.firstMatch(in: text, range: range) != nil
            else { return nil }
            return keyword.note
        }
    }

    // MARK: Model instructions, prompt and answer schema

    public static let instructions = """
        You find paid sponsor segments in YouTube video transcripts.

        You get part of a video's transcript. Each line starts with the second of the video at \
        which it is spoken, in square brackets, like [66]. Lines are a few words each, often \
        without punctuation, and may contain speech-recognition errors.

        A sponsor segment is a paid advertisement read inside the video: the creator promotes a \
        product, service or company that paid for the placement. It usually has three parts:
        1. A transition into the ad, such as "but first", "before we continue", "this video is \
        sponsored by", "today's video is brought to you by", "thanks to X for sponsoring" or \
        "a quick word from our sponsor".
        2. A description of the sponsor's product, its features and its benefits.
        3. A call to action, such as "link in the description", a discount or promo code, a \
        website address or a free trial.

        For each sponsor segment, give:
        - start: the number of the line where the transition into the ad begins.
        - end: the number of the last line of the ad, usually the call to action. Cover the \
        whole read, from the transition to the call to action, not only the line that names \
        the sponsor.
        - kind: "sponsor" for a paid ad read. "selfpromo" when the creator promotes their own \
        merchandise, channel, Patreon or giveaway and no other company paid for it. "none" if \
        you are unsure it is an ad at all.
        - confidence: a number from 0 to 1, how sure you are that this is a paid placement.

        Normal content is not a sponsor segment. A product review, a comparison, a benchmark or \
        a tutorial about a product is content, unless the creator says it is sponsored or gives \
        a link or code for the company that paid. If the transcript has no sponsor segment, \
        return an empty list of segments. Only use line numbers that appear in the transcript.
        """

    public static func prompt(for chunk: Chunk) -> String {
        """
        Transcript lines from second \(label(chunk.start)) to second \(label(chunk.end)):
        \(chunk.text)

        List every sponsor segment in these lines, or return an empty list of segments.
        """
    }

    /// A property of the answer's segment object, as data the app turns into a
    /// `DynamicGenerationSchema.Property`.
    public struct SchemaProperty: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case number
            /// A string that must be one of `choices`.
            case choice([String])
        }

        public var name: String
        public var description: String
        public var kind: Kind
    }

    /// The answer: `{segments: [{start, end, kind, confidence}]}`.
    public enum AnswerSchema {
        public static let rootName = "SponsorDetectionAnswer"
        public static let rootDescription = "The sponsor segments found in the transcript lines."
        public static let segmentsProperty = "segments"
        public static let segmentsDescription = "Every sponsor segment in the lines; empty if there is none."
        public static let segmentName = "SponsorSegment"
        public static let segmentDescription = "One ad read, from its first line to its last line."
        public static let kindName = "SegmentKind"
        /// More than this in a ~6,000-character window would be noise.
        public static let maximumSegments = 4
        public static let segmentProperties: [SchemaProperty] = [
            SchemaProperty(name: "start", description: "The line number (seconds) where the transition into the ad begins.",
                           kind: .number),
            SchemaProperty(name: "end", description: "The line number (seconds) of the last line of the ad, usually its call to action.",
                           kind: .number),
            SchemaProperty(name: "kind", description: "sponsor = paid ad read; selfpromo = the creator's own promotion; none = not an ad.",
                           kind: .choice(Kind.allCases.map(\.rawValue))),
            SchemaProperty(name: "confidence", description: "From 0 to 1: how sure you are that this is a paid placement.",
                           kind: .number),
        ]
    }

    // MARK: Answer validation

    /// What the model may answer as `kind`.
    public enum Kind: String, CaseIterable, Sendable {
        case sponsor, selfpromo, none
    }

    public struct Options: Equatable, Sendable {
        /// Answers below this confidence are dropped.
        public var minimumConfidence: Double
        /// Shorter or longer segments (after snapping) are dropped.
        public var minimumSeconds: Double
        public var maximumSeconds: Double
        /// How far outside the chunk's time range an answer may reach before it is dropped.
        public var toleranceSeconds: Double
        /// v1 suggests sponsor reads only; this also keeps `selfpromo` answers.
        public var includeSelfPromo: Bool

        public init(minimumConfidence: Double = 0.6, minimumSeconds: Double = 8, maximumSeconds: Double = 300,
                    toleranceSeconds: Double = 5, includeSelfPromo: Bool = false) {
            self.minimumConfidence = minimumConfidence
            self.minimumSeconds = minimumSeconds
            self.maximumSeconds = maximumSeconds
            self.toleranceSeconds = toleranceSeconds
            self.includeSelfPromo = includeSelfPromo
        }

        public static let standard = Options()
    }

    /// The valid segments in the model's JSON answer for `chunk`, snapped to the chunk's cues.
    /// Anything malformed is dropped silently; garbage → [].
    /// - Each entry needs finite `start` < `end` (numbers, or numeric strings), a kind that is
    ///   kept (`sponsor`; `selfpromo` with `includeSelfPromo`) and `confidence` ≥ the minimum.
    /// - `start` and `end` must lie within the chunk's range ± `toleranceSeconds`.
    /// - Snapping: the model answers in line labels (whole seconds, rounded down), so `start`
    ///   becomes the start of the last cue labelled ≤ `start`, and `end` the end of the last cue
    ///   labelled ≤ `end`; the segment then covers both lines whole.
    /// - After snapping it must last `minimumSeconds`…`maximumSeconds`.
    public static func segments(fromModelJSON json: String, chunk: Chunk, options: Options = .standard) -> [SkipSegment] {
        guard !chunk.cues.isEmpty,
              let answer = try? JSONDecoder().decode(Answer.self, from: Data(json.utf8))
        else { return [] }
        var out: [SkipSegment] = []
        for entry in answer.segments {
            guard let start = entry.start?.value, let end = entry.end?.value,
                  let confidence = entry.confidence?.value,
                  let kindRaw = entry.kind,
                  let kind = Kind(rawValue: kindRaw.lowercased().trimmingCharacters(in: .whitespaces)),
                  start < end, confidence >= options.minimumConfidence,
                  kind == .sponsor || (kind == .selfpromo && options.includeSelfPromo),
                  start >= chunk.start - options.toleranceSeconds,
                  end <= chunk.end + options.toleranceSeconds
            else { continue }
            let first = cue(labelledAtOrBefore: start, in: chunk) ?? chunk.cues[0]
            let last = cue(labelledAtOrBefore: end, in: chunk) ?? chunk.cues[0]
            let snapped = SkipSegment(start: first.start, end: max(first.end, last.end), category: kind.rawValue)
            let duration = snapped.end - snapped.start
            guard duration >= options.minimumSeconds, duration <= options.maximumSeconds else { continue }
            out.append(snapped)
        }
        return out
    }

    private static func cue(labelledAtOrBefore seconds: Double, in chunk: Chunk) -> Captions.Cue? {
        let target = label(seconds)
        return chunk.cues.last(where: { label($0.start) <= target })
    }

    // Lenient answer types: one bad entry (or field) doesn't fail the rest.
    private struct Answer: Decodable {
        let segments: [Entry]

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            segments = try c.decode([Lenient<Entry>].self, forKey: .segments).compactMap(\.value)
        }

        enum CodingKeys: String, CodingKey { case segments }
    }

    private struct Entry: Decodable {
        let start, end, confidence: Number?
        let kind: String?

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            start = try? c.decodeIfPresent(Number.self, forKey: .start)
            end = try? c.decodeIfPresent(Number.self, forKey: .end)
            confidence = try? c.decodeIfPresent(Number.self, forKey: .confidence)
            kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        }

        enum CodingKeys: String, CodingKey { case start, end, confidence, kind }
    }

    /// A finite number, written as a JSON number or a numeric string.
    private struct Number: Decodable {
        let value: Double

        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            let raw: Double? = (try? c.decode(Double.self))
                ?? (try? c.decode(String.self)).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard let raw, raw.isFinite else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a finite number")
            }
            value = raw
        }
    }

    private struct Lenient<T: Decodable>: Decodable {
        let value: T?

        init(from decoder: any Decoder) throws {
            value = try? T(from: decoder)
        }
    }

    /// All chunks' segments, sorted; segments of the same category that overlap or are at most
    /// `gapSeconds` apart are joined (overlapping windows report the same read twice).
    public static func merge(_ segments: [SkipSegment], gapSeconds: Double = 1) -> [SkipSegment] {
        let sorted = segments.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var out: [SkipSegment] = []
        for segment in sorted {
            if let index = out.lastIndex(where: { $0.category == segment.category }),
               segment.start <= out[index].end + gapSeconds {
                out[index].end = max(out[index].end, segment.end)
            } else {
                out.append(segment)
            }
        }
        return out.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    // MARK: Model availability and the Debug log

    /// The on-device model's state, as the Settings screen shows it.
    public enum ModelStatus: Equatable, Sendable {
        case available
        case appleIntelligenceOff
        case modelNotReady
        case deviceNotEligible
        /// The OS has no FoundationModels (before iOS 26) or answered something unknown.
        case unsupported

        public var message: String {
            switch self {
            case .available: "Apple Intelligence is available."
            case .appleIntelligenceOff: "Apple Intelligence is off. Turn it on in Settings › Apple Intelligence & Siri."
            case .modelNotReady: "The Apple Intelligence model is still downloading or not ready. Try again later."
            case .deviceNotEligible: "Not supported on this device (needs an Apple Intelligence iPhone)."
            case .unsupported: "On-device AI isn't available on this iOS version."
            }
        }

        public var isAvailable: Bool { self == .available }
    }

    /// What one detection run did, for the one-line Debug-log summary.
    public struct Report: Equatable, Sendable {
        public var chunks: Int
        public var flagged: Int
        /// Chunks whose model call failed (guardrails, context size, …): no detections for them.
        public var failed: Int
        public var segments: [SkipSegment]
        public var seconds: Double

        public init(chunks: Int, flagged: Int, failed: Int, segments: [SkipSegment], seconds: Double) {
            self.chunks = chunks
            self.flagged = flagged
            self.failed = failed
            self.segments = segments
            self.seconds = seconds
        }

        /// e.g. `AI: 3/41 chunks flagged, 1 segment 66–103 s, 7.2 s`.
        public var summary: String {
            var parts = ["AI: \(flagged)/\(chunks) chunks flagged"]
            if failed > 0 { parts.append("\(failed) failed") }
            switch segments.count {
            case 0: parts.append("no segments")
            default:
                let ranges = segments.map { "\(Int($0.start.rounded()))–\(Int($0.end.rounded())) s" }
                parts.append("\(segments.count) segment\(segments.count == 1 ? "" : "s") " + ranges.joined(separator: ", "))
            }
            parts.append(String(format: "%.1f s", seconds))
            return parts.joined(separator: ", ")
        }
    }
}

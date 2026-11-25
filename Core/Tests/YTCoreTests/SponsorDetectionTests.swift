// On-device sponsor detection, pure parts (PLAN.md §6.5; `captionTracks`/`suggestedSegments`, §5.4).
// Owner: Module D. Fixture: TestVectors/transcripts/2026-11-25-timedtext-WWfjoGZmrTo.json, an
// anonymous json3 auto-caption transcript (first 420 s) with SponsorBlock's segments as ground
// truth: selfpromo 23.944–65.833 s, sponsor 65.733–104.28 s. The sponsor read begins "but first
// paying some bills, the Evolve X2 PC Tower from fantex…" and only says "sponsored link in the
// description" at its end.

import Foundation
import Testing
@testable import YTCore

@Suite("SponsorDetection")
struct SponsorDetectionTests {
    static let fixture = "TestVectors/transcripts/2026-11-25-timedtext-WWfjoGZmrTo.json"
    static let truthSponsor = (start: 65.733, end: 104.28)

    static func fixtureBody() throws -> Data {
        let object = try Repo.jsonObject(fixture)
        let body = try #require(object["body"])
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func fixtureCues() throws -> [Captions.Cue] {
        try Captions.cues(fromJSON3: fixtureBody())
    }

    // MARK: Caption tracks

    static let base = "https://m.youtube.com/api/timedtext?v=WWfjoGZmrTo&caps=asr&lang=en"

    @Test("captionTracks reply: decodes tracks, drops malformed ones, rejects non-objects")
    func captionTracksReply() throws {
        let json = """
            {"videoId":"WWfjoGZmrTo","tracks":[
              {"baseUrl":"\(Self.base)","languageCode":"en","kind":"asr","name":"English (auto-generated)"},
              {"baseUrl":"https://m.youtube.com/api/timedtext?v=x&lang=fr","languageCode":"fr"},
              {"languageCode":"de"},
              "nope"
            ]}
            """
        let reply = try Captions.captionTracks(fromJSON: json)
        #expect(reply.videoId == "WWfjoGZmrTo")
        #expect(reply.tracks == [
            Captions.CaptionTrack(baseUrl: Self.base, languageCode: "en", kind: "asr", name: "English (auto-generated)"),
            Captions.CaptionTrack(baseUrl: "https://m.youtube.com/api/timedtext?v=x&lang=fr", languageCode: "fr"),
        ])
        #expect(try Captions.captionTracks(fromJSON: #"{"videoId":null,"tracks":[]}"#)
            == Captions.CaptionTracksReply(videoId: nil, tracks: []))
        #expect(throws: Captions.DecodeError.malformed) { try Captions.captionTracks(fromJSON: "[]") }
        #expect(throws: Captions.DecodeError.malformed) { try Captions.captionTracks(fromJSON: "garbage") }
    }

    @Test("track choice: manual English, then English asr, else none with a reason")
    func trackChoice() {
        let asrEn = Captions.CaptionTrack(baseUrl: "a", languageCode: "en", kind: "asr")
        let manualEnGB = Captions.CaptionTrack(baseUrl: "b", languageCode: "en-GB")
        let manualFr = Captions.CaptionTrack(baseUrl: "c", languageCode: "fr")
        let asrDe = Captions.CaptionTrack(baseUrl: "d", languageCode: "de", kind: "asr")
        #expect(Captions.chooseTrack([asrEn, manualFr, manualEnGB]) == .track(manualEnGB))
        #expect(Captions.chooseTrack([manualFr, asrEn]) == .track(asrEn))
        #expect(Captions.chooseTrack([]) == .none(reason: "no caption tracks"))
        #expect(Captions.chooseTrack([manualFr, asrDe]) == .none(reason: "no English track (offered: fr, de (auto))"))
    }

    @Test("json3 URL: sets fmt=json3, keeps the signed query, rejects other hosts and paths")
    func json3URL() {
        #expect(Captions.json3URL(baseUrl: Self.base)?.absoluteString == Self.base + "&fmt=json3")
        #expect(Captions.json3URL(baseUrl: "https://www.youtube.com/api/timedtext?v=x&fmt=srv3&sig=a%2Bb")?.absoluteString
            == "https://www.youtube.com/api/timedtext?v=x&sig=a%2Bb&fmt=json3")
        for bad in ["http://m.youtube.com/api/timedtext?v=x", "https://evil.example/api/timedtext?v=x",
                    "https://youtube.com.evil.example/api/timedtext", "https://m.youtube.com/watch?v=x",
                    "/api/timedtext?v=x", "", "not a url"] {
            #expect(Captions.json3URL(baseUrl: bad) == nil, "\(bad)")
        }
    }

    // MARK: json3

    @Test("json3: the fixture parses into sorted, non-empty, non-overlapping cues")
    func parseFixture() throws {
        let cues = try Self.fixtureCues()
        #expect(cues.count > 150)
        #expect(cues.first?.text == "all right so today we're going to be")
        #expect(abs((cues.first?.start ?? -1) - 0.08) < 0.001)
        #expect(cues.allSatisfy { !$0.text.isEmpty && !$0.text.contains("\n") && $0.end >= $0.start })
        #expect(zip(cues, cues.dropFirst()).allSatisfy { $0.start <= $1.start && $0.end <= $1.start })
        let paying = try #require(cues.first { $0.text.contains("paying some") })
        #expect(abs(paying.start - 65.96) < 0.001)
        #expect(abs(paying.end - 67.799) < 0.001)  // clamped to the next cue, not 65.96 + 5.0
        #expect(cues.last.map { $0.start < 420 } == true)
    }

    @Test("json3: entities decoded, whitespace collapsed, empty events dropped, sorted")
    func parseSnippet() throws {
        let json = #"""
            {"events":[
              {"tStartMs":5000,"dDurationMs":1000,"segs":[{"utf8":"tom &amp; jerry&#39;s  &quot;show&quot;"}]},
              {"tStartMs":0,"dDurationMs":9000},
              {"tStartMs":1000,"dDurationMs":2000,"segs":[{"utf8":"\n"}]},
              {"tStartMs":2000,"dDurationMs":2000,"segs":[{"utf8":"a\n"},{"utf8":"b &#x41; &lt;3 &bogus; & c"}]},
              {"tStartMs":3000,"segs":[{"utf8":"no duration"}]}
            ]}
            """#
        let cues = try Captions.cues(fromJSON3: Data(json.utf8))
        #expect(cues == [
            Captions.Cue(start: 2, end: 3, text: "a b A <3 &bogus; & c"),
            Captions.Cue(start: 3, end: 5, text: "no duration"),
            Captions.Cue(start: 5, end: 6, text: "tom & jerry's \"show\""),
        ])
        #expect(throws: Captions.DecodeError.malformed) { try Captions.cues(fromJSON3: Data("[1,2]".utf8)) }
        #expect(try Captions.cues(fromJSON3: Data("{}".utf8)) == [])
    }

    // MARK: Chunks and prefilter

    @Test("chunks: within the character budget, overlapping by about 20 s, covering every cue")
    func chunking() throws {
        let cues = try Self.fixtureCues()
        let chunks = SponsorDetection.chunks(cues, maxCharacters: 1_200, overlapSeconds: 20)
        #expect(chunks.count > 3)
        #expect(chunks.allSatisfy { $0.text.count <= 1_200 })
        #expect(chunks.first?.cues.first == cues.first)
        #expect(chunks.last?.cues.last == cues.last)
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            #expect(b.start > a.start)
            #expect(b.start <= a.end - 15, "windows overlap: \(a.start)–\(a.end) then \(b.start)")
        }
        // The default budget holds the whole 420 s fixture in one or two windows.
        #expect((1...2).contains(SponsorDetection.chunks(cues).count))
        #expect(SponsorDetection.chunks([]) == [])
    }

    @Test("chunks: lines are '[whole seconds] text'")
    func rendering() throws {
        let chunk = SponsorDetection.Chunk(cues: [
            Captions.Cue(start: 65.96, end: 67.799, text: "first paying some"),
            Captions.Cue(start: 67.799, end: 70.96, text: "bills the Evolve X2 PC Tower from fantex"),
        ])
        #expect(chunk.text == "[65] first paying some\n[67] bills the Evolve X2 PC Tower from fantex")
        let prompt = SponsorDetection.prompt(for: chunk)
        #expect(prompt.contains("from second 65 to second 70"))
        #expect(prompt.contains(chunk.text))
    }

    static func window(_ cues: [Captions.Cue], from: Double, to: Double) -> SponsorDetection.Chunk {
        SponsorDetection.Chunk(cues: cues.filter { $0.start >= from && $0.start < to })
    }

    @Test("prefilter: the sponsor read (66–104 s) passes, also when split across lines")
    func prefilterSponsor() throws {
        let cues = try Self.fixtureCues()
        let read = Self.window(cues, from: 65, to: 105)
        let matches = SponsorDetection.prefilterMatches(read)
        #expect(matches.contains { $0.contains("paying some bills") })
        #expect(matches.contains { $0.contains("link in the description") })
        #expect(matches.contains { $0.contains("sponsor") })
        // Every window of the default chunking that covers the read passes too.
        let covering = SponsorDetection.chunks(cues).filter { $0.start <= 66 && $0.end >= 104 }
        #expect(!covering.isEmpty)
        #expect(covering.allSatisfy { !SponsorDetection.prefilterMatches($0).isEmpty })
    }

    @Test("prefilter: plain content (PCIe benchmark talk) doesn't pass")
    func prefilterPlain() throws {
        let cues = try Self.fixtureCues()
        let plain = Self.window(cues, from: 106, to: 160)
        #expect(plain.cues.count > 10)
        #expect(SponsorDetection.prefilterMatches(plain) == [])
        #expect(SponsorDetection.prefilterMatches(SponsorDetection.Chunk(cues: [])) == [])
    }

    @Test("prefilter: every keyword is a valid pattern with a note; phrase examples match")
    func keywords() throws {
        for keyword in SponsorDetection.keywords {
            #expect(throws: Never.self) { try NSRegularExpression(pattern: keyword.pattern) }
            #expect(!keyword.note.isEmpty)
        }
        let examples = [
            "today's video is brought to you by", "thanks to nord vpn for sponsoring", "use code LINUS",
            "get 20 percent off", "start your free trial", "the link in the description", "squarespace",
            "raid shadow legends", "AG1 by athletic greens", "this video is sponsored by",
        ]
        for example in examples {
            let chunk = SponsorDetection.Chunk(cues: [Captions.Cue(start: 0, end: 1, text: example)])
            #expect(!SponsorDetection.prefilterMatches(chunk).isEmpty, "\(example)")
        }
    }

    // MARK: Instructions and schema

    @Test("instructions, prompt and schema are present and say what they must")
    func instructionsAndSchema() {
        let text = SponsorDetection.instructions
        for phrase in ["sponsor", "[66]", "but first", "this video is sponsored by", "call to action",
                       "link in the description", "product review", "empty list", "start", "end", "kind", "confidence"] {
            #expect(text.contains(phrase), "\(phrase)")
        }
        let schema = SponsorDetection.AnswerSchema.self
        #expect(schema.segmentsProperty == "segments")
        #expect(schema.segmentProperties.map(\.name) == ["start", "end", "kind", "confidence"])
        #expect(schema.segmentProperties.allSatisfy { !$0.description.isEmpty })
        #expect(schema.segmentProperties[2].kind == .choice(["sponsor", "selfpromo", "none"]))
        #expect(schema.maximumSegments > 0)
    }

    // MARK: Answer validation

    static func fixtureChunk() throws -> SponsorDetection.Chunk {
        try Self.window(Self.fixtureCues(), from: 40, to: 130)
    }

    @Test("answer: a simulated sponsor answer [66, 103] lands within ~1 s of the ground truth")
    func simulatedAnswer() throws {
        let chunk = try Self.fixtureChunk()
        let json = #"{"segments":[{"start":66,"end":103,"kind":"sponsor","confidence":0.9}]}"#
        let segments = SponsorDetection.segments(fromModelJSON: json, chunk: chunk)
        let segment = try #require(segments.first)
        #expect(segments.count == 1)
        #expect(segment.category == "sponsor")
        #expect(abs(segment.start - Self.truthSponsor.start) <= 1, "start \(segment.start)")
        #expect(abs(segment.end - Self.truthSponsor.end) <= 1, "end \(segment.end)")
        // Snapped to cue boundaries: 65.96 (the "first paying some" line) and the end of line [102].
        #expect(abs(segment.start - 65.96) < 0.001)
        #expect(abs(segment.end - 105.24) < 0.001)
    }

    @Test("answer: low confidence, wrong kind, out of range, too short or too long are dropped")
    func validation() throws {
        let chunk = try Self.fixtureChunk()
        func run(_ entries: String, _ options: SponsorDetection.Options = .standard) -> [SkipSegment] {
            SponsorDetection.segments(fromModelJSON: #"{"segments":["# + entries + "]}", chunk: chunk, options: options)
        }
        #expect(run(#"{"start":66,"end":103,"kind":"sponsor","confidence":0.5}"#) == [])
        #expect(run(#"{"start":66,"end":103,"kind":"none","confidence":0.9}"#) == [])
        #expect(run(#"{"start":24,"end":65,"kind":"selfpromo","confidence":0.9}"#) == [])  // 24 is outside the chunk anyway
        #expect(run(#"{"start":42,"end":64,"kind":"selfpromo","confidence":0.9}"#) == [])
        #expect(run(#"{"start":42,"end":64,"kind":"selfpromo","confidence":0.9}"#,
                    SponsorDetection.Options(includeSelfPromo: true)).map(\.category) == ["selfpromo"])
        #expect(run(#"{"start":10,"end":103,"kind":"sponsor","confidence":0.9}"#) == [])   // before the chunk
        #expect(run(#"{"start":66,"end":400,"kind":"sponsor","confidence":0.9}"#) == [])   // after the chunk
        #expect(run(#"{"start":103,"end":66,"kind":"sponsor","confidence":0.9}"#) == [])   // reversed
        #expect(run(#"{"start":66,"end":68,"kind":"sponsor","confidence":0.9}"#) == [])    // < 8 s after snapping
        #expect(run(#"{"start":66,"end":103,"kind":"sponsor","confidence":0.9}"#,
                    SponsorDetection.Options(maximumSeconds: 30)) == [])                    // > max
        // Numeric strings and a capitalised kind are accepted; a bad sibling doesn't spoil it.
        #expect(run(#"{"start":"66","end":"103.5","kind":"Sponsor","confidence":"0.8"}, {"start":true}"#).count == 1)
    }

    @Test("answer: garbage → []", arguments: [
        "", "null", "[]", "{}", "not json", #"{"segments":"x"}"#, #"{"segments":[1,2,3]}"#,
        #"{"segments":[{"start":null,"end":103,"kind":"sponsor","confidence":0.9}]}"#,
        #"{"segments":[{"start":66,"end":103,"kind":"ad","confidence":0.9}]}"#,
        #"{"segments":[{"start":66,"end":103,"kind":"sponsor"}]}"#,
        #"{"segments":[{"start":"NaN","end":103,"kind":"sponsor","confidence":0.9}]}"#,
    ])
    func garbage(json: String) throws {
        #expect(SponsorDetection.segments(fromModelJSON: json, chunk: try Self.fixtureChunk()) == [])
    }

    @Test("merge: overlapping windows' answers join; categories stay apart; sorted")
    func merging() {
        let merged = SponsorDetection.merge([
            SkipSegment(start: 90, end: 105, category: "sponsor"),
            SkipSegment(start: 65.96, end: 95, category: "sponsor"),
            SkipSegment(start: 300, end: 330, category: "sponsor"),
            SkipSegment(start: 330.5, end: 340, category: "sponsor"),
            SkipSegment(start: 24, end: 66, category: "selfpromo"),
        ])
        #expect(merged == [
            SkipSegment(start: 24, end: 66, category: "selfpromo"),
            SkipSegment(start: 65.96, end: 105, category: "sponsor"),
            SkipSegment(start: 300, end: 340, category: "sponsor"),
        ])
        #expect(SponsorDetection.merge([]) == [])
    }

    // MARK: Status and summary

    @Test("model status messages and the Debug-log summary line")
    func statusAndSummary() {
        let all: [SponsorDetection.ModelStatus] = [.available, .appleIntelligenceOff, .modelNotReady, .deviceNotEligible, .unsupported]
        #expect(all.allSatisfy { !$0.message.isEmpty })
        #expect(all.filter(\.isAvailable) == [.available])
        #expect(SponsorDetection.ModelStatus.appleIntelligenceOff.message.contains("Apple Intelligence is off"))
        let report = SponsorDetection.Report(chunks: 41, flagged: 3, failed: 0,
                                             segments: [SkipSegment(start: 65.96, end: 103.2, category: "sponsor")],
                                             seconds: 7.24)
        #expect(report.summary == "AI: 3/41 chunks flagged, 1 segment 66–103 s, 7.2 s")
        #expect(SponsorDetection.Report(chunks: 2, flagged: 1, failed: 1, segments: [], seconds: 0.5).summary
            == "AI: 1/2 chunks flagged, 1 failed, no segments, 0.5 s")
    }
}

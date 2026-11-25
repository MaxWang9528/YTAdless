// SponsorBlock request/response (PLAN.md §6.4, `sponsorSegments` §5.4). Owner: Module D.
// Fixture: TestVectors/sponsorblock/2026-11-25-skipSegments-5f6b.json, an anonymous live response
// for prefix 5f6b (= sha256("dQw4w9WgXcQ").prefix(4)), trimmed to three of its 89 videos.

import Foundation
import Testing
@testable import YTCore

@Suite("SponsorBlock")
struct SponsorBlockTests {
    static let fixture = "TestVectors/sponsorblock/2026-11-25-skipSegments-5f6b.json"
    static let all = Set(SponsorBlock.Category.allCases)

    // MARK: Categories

    @Test("categories: API names, defaults, and persistence round-trip")
    func categories() {
        #expect(SponsorBlock.Category.allCases.map(\.rawValue)
            == ["sponsor", "selfpromo", "interaction", "intro", "outro", "preview", "music_offtopic", "filler"])
        #expect(SponsorBlock.Category.defaults == [.sponsor, .selfpromo, .interaction])
        #expect(SponsorBlock.Category.rawValues(SponsorBlock.Category.defaults) == ["sponsor", "selfpromo", "interaction"])
        #expect(SponsorBlock.Category.set(fromRawValues: ["filler", "nope", "music_offtopic"]) == [.filler, .musicOfftopic])
        #expect(SponsorBlock.Category.allCases.allSatisfy { !$0.displayName.isEmpty })
    }

    // MARK: Request

    @Test("request: hash-prefix path, repeated category, actionType=skip")
    func request() throws {
        let url = try SponsorBlock.requestURL(hashPrefix: "5f6b", categories: [.interaction, .sponsor])
        #expect(url.absoluteString
            == "https://sponsor.ajay.app/api/skipSegments/5f6b?category=sponsor&category=interaction&actionType=skip")
    }

    @Test("request: the prefix must be 4 lowercase hex characters",
          arguments: ["5F6B", "5f6", "5f6b0", "", "5f6g", "../a", "5f 6"])
    func invalidPrefix(prefix: String) {
        #expect(throws: SponsorBlock.RequestError.invalidPrefix(prefix)) {
            try SponsorBlock.requestURL(hashPrefix: prefix, categories: [.sponsor])
        }
    }

    @Test("request: no categories is an error")
    func noCategories() {
        #expect(throws: SponsorBlock.RequestError.noCategories) {
            try SponsorBlock.requestURL(hashPrefix: "5f6b", categories: [])
        }
    }

    // MARK: Response (fixture)

    @Test("fixture: only the requested video's segments, sorted")
    func fixturePicksVideo() throws {
        let data = try Repo.data(Self.fixture)
        let segments = try SponsorBlock.segments(from: data, statusCode: 200, videoId: "1a4_xdSUvRg", categories: Self.all)
        #expect(segments == [
            SkipSegment(start: 0, end: 17.962606, category: "sponsor"),
            SkipSegment(start: 104.90781, end: 138.03996, category: "sponsor"),
            SkipSegment(start: 785.8555, end: 825.181, category: "sponsor"),
        ])
    }

    @Test("fixture: overlapping selfpromo + sponsor merge into one; the 1.05 s interaction stays")
    func fixtureMerges() throws {
        let data = try Repo.data(Self.fixture)
        let segments = try SponsorBlock.segments(from: data, statusCode: 200, videoId: "WWfjoGZmrTo", categories: Self.all)
        #expect(segments == [
            SkipSegment(start: 23.944, end: 104.28, category: "selfpromo"),
            SkipSegment(start: 939.604, end: 940.658, category: "interaction"),
        ])
    }

    @Test("fixture: a disabled category is filtered before merging, so its span isn't skipped")
    func fixtureFiltersBeforeMerge() throws {
        let data = try Repo.data(Self.fixture)
        let segments = try SponsorBlock.segments(from: data, statusCode: 200, videoId: "WWfjoGZmrTo", categories: [.sponsor])
        #expect(segments == [SkipSegment(start: 65.733, end: 104.28, category: "sponsor")])
    }

    @Test("fixture: a video not in the response has no segments")
    func fixtureOtherVideo() throws {
        let data = try Repo.data(Self.fixture)
        #expect(try SponsorBlock.segments(from: data, statusCode: 200, videoId: "dQw4w9WgXcQ", categories: Self.all) == [])
    }

    // MARK: Response (edge cases)

    static func response(_ segments: String, videoID: String = "AAAAAAAAAAA") -> Data {
        Data(#"[{"videoID":"\#(videoID)","segments":[\#(segments)]}]"#.utf8)
    }

    @Test("edge: non-skip actions, short, disallowed, negative and inverted segments are dropped")
    func dropsInvalid() throws {
        let data = Self.response("""
            {"segment":[10,20],"category":"sponsor","actionType":"mute"},
            {"segment":[30,30.5],"category":"sponsor","actionType":"skip"},
            {"segment":[40,50],"category":"filler","actionType":"skip"},
            {"segment":[-5,3],"category":"sponsor","actionType":"skip"},
            {"segment":[90,80],"category":"sponsor","actionType":"skip"},
            {"segment":[60],"category":"sponsor","actionType":"skip"},
            {"segment":"x","category":"sponsor","actionType":"skip"},
            {"segment":[100,101],"category":"intro","actionType":"skip","UUID":"u","votes":3}
            """)
        let segments = try SponsorBlock.segments(from: data, statusCode: 200, videoId: "AAAAAAAAAAA",
                                                 categories: [.sponsor, .intro])
        #expect(segments == [SkipSegment(start: 100, end: 101, category: "intro")])
    }

    @Test("edge: contained and touching segments merge; disjoint ones don't")
    func merging() {
        let merged = SponsorBlock.merged([
            SkipSegment(start: 50, end: 60, category: "outro"),
            SkipSegment(start: 10, end: 40, category: "sponsor"),
            SkipSegment(start: 15, end: 20, category: "selfpromo"),
            SkipSegment(start: 40, end: 45, category: "interaction"),
        ])
        #expect(merged == [
            SkipSegment(start: 10, end: 45, category: "sponsor"),
            SkipSegment(start: 50, end: 60, category: "outro"),
        ])
    }

    @Test("edge: 404 means no segments, whatever the body")
    func notFound() throws {
        #expect(try SponsorBlock.segments(from: Data("[]".utf8), statusCode: 404, videoId: "x", categories: Self.all) == [])
        #expect(try SponsorBlock.segments(from: Data("Not Found".utf8), statusCode: 404, videoId: "x", categories: Self.all) == [])
    }

    @Test("edge: other statuses and malformed bodies throw", arguments: [400, 429, 500, 503])
    func errors(status: Int) {
        #expect(throws: SponsorBlock.ResponseError.httpStatus(status)) {
            try SponsorBlock.segments(from: Data("[]".utf8), statusCode: status, videoId: "x", categories: Self.all)
        }
    }

    @Test("edge: an undecodable 200 body throws .malformed")
    func malformed() {
        for body in ["", "{}", "<html>", #"[{"segments":[]}]"#] {
            #expect(throws: SponsorBlock.ResponseError.malformed) {
                try SponsorBlock.segments(from: Data(body.utf8), statusCode: 200, videoId: "x", categories: Self.all)
            }
        }
    }

    @Test("result encodes as the sponsorSegments command")
    func command() throws {
        let data = try Repo.data(Self.fixture)
        let segments = try SponsorBlock.segments(from: data, statusCode: 200, videoId: "aQp-iM0bCs4", categories: [.sponsor])
        #expect(JSCommand.sponsorSegments(videoId: "aQp-iM0bCs4", segments: segments).argumentsJSON
            == #"{"autoSkip":true,"segments":[{"category":"sponsor","end":31.861,"start":0}],"videoId":"aQp-iM0bCs4"}"#)
    }
}

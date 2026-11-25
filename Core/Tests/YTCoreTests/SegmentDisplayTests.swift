// SegmentDisplay (Debug › Segments tab, PLAN.md §6.5). Owner: Module D.

import Foundation
import Testing
@testable import YTCore

@Suite("SponsorBlock › segment display")
struct SegmentDisplayTests {
    @Test("timestamps: m:ss, h:mm:ss, rounding down, junk → 0:00")
    func timestamps() {
        #expect(SegmentDisplay.timestamp(0) == "0:00")
        #expect(SegmentDisplay.timestamp(65.733) == "1:05")
        #expect(SegmentDisplay.timestamp(104.28) == "1:44")
        #expect(SegmentDisplay.timestamp(3599.9) == "59:59")
        #expect(SegmentDisplay.timestamp(3723) == "1:02:03")
        #expect(SegmentDisplay.timestamp(-4) == "0:00")
        #expect(SegmentDisplay.timestamp(.nan) == "0:00")
        #expect(SegmentDisplay.timestamp(.infinity) == "0:00")
    }

    @Test("range, length and total")
    func rangeAndLength() {
        let a = SkipSegment(start: 65.733, end: 104.28, category: "sponsor")
        let b = SkipSegment(start: 600, end: 725, category: "outro")
        #expect(SegmentDisplay.range(a) == "1:05 – 1:44")
        #expect(SegmentDisplay.length(a) == "39 s")
        #expect(SegmentDisplay.length(b) == "2 min 5 s")
        #expect(SegmentDisplay.length(SkipSegment(start: 5, end: 3, category: "x")) == "0 s")
        #expect(abs(SegmentDisplay.totalSeconds([a, b]) - 163.547) < 0.001)
    }

    @Test("colours match sponsorblock.js CONFIG.CATEGORY_COLORS; names are SponsorBlock's")
    func coloursAndNames() throws {
        let js = String(decoding: try Repo.data("Core/Sources/YTAssets/scripts/sponsorblock.js"), as: UTF8.self)
        for category in SponsorBlock.Category.allCases {
            let hex = SegmentDisplay.colorHex(category.rawValue)
            #expect(js.contains("\(category.rawValue): '\(hex)'"), "\(category.rawValue) is \(hex) in sponsorblock.js")
            #expect(SegmentDisplay.rgb(hex) != nil)
            #expect(SegmentDisplay.name(category.rawValue) == category.displayName)
        }
        #expect(SegmentDisplay.colorHex("unknown") == "#00d400")
        #expect(SegmentDisplay.name("unknown") == "unknown")
        let orange = try #require(SegmentDisplay.rgb("#ff9900"))
        #expect(orange.red == 1 && abs(orange.green - 0.6) < 1e-9 && orange.blue == 0)
        #expect(SegmentDisplay.rgb("ff9900") == nil)
        #expect(SegmentDisplay.rgb("#zzzzzz") == nil)
    }
}

import Testing
@testable import YTCore

@Suite("Presentation › app full screen")
struct AppFullscreenTests {
    @Test("enter from portrait rotates to landscape; enter or exit in landscape goes back; exit in portrait does nothing")
    func targets() {
        #expect(AppFullscreen.target(enter: true, isLandscape: false) == .landscape)
        #expect(AppFullscreen.target(enter: true, isLandscape: true) == .portrait, "the page's button never leaves 'enter'")
        #expect(AppFullscreen.target(enter: false, isLandscape: true) == .portrait)
        #expect(AppFullscreen.target(enter: false, isLandscape: false) == nil)
    }

    @Test("going landscape expands a docked or mini player; hidden stays hidden; portrait keeps the mode")
    func presentation() {
        #expect(AppFullscreen.presentation(entering: .landscape, from: .docked) == .expanded)
        #expect(AppFullscreen.presentation(entering: .landscape, from: .mini(.bottomTrailing)) == .expanded)
        #expect(AppFullscreen.presentation(entering: .landscape, from: .expanded) == .expanded)
        #expect(AppFullscreen.presentation(entering: .landscape, from: .hidden) == .hidden)
        #expect(AppFullscreen.presentation(entering: .portrait, from: .expanded) == .expanded)
    }
}

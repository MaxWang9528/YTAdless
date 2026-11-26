// AppFullscreenController — owner: Module C (PLAN.md §6.3).
//
// Carries out `fullscreenRequest {enter}` (player-bridge.js): instead of WebKit's video full
// screen, rotate the window scene; the player's expanded landscape layout is the app's full screen,
// and the page — with the SponsorBlock Skip button — stays visible there. Which way to rotate comes
// from `AppFullscreen` (YTCore, tested). Only the interface rotates: the webviews keep their place
// in the tree (D2), so the video neither pauses nor reloads.

import UIKit
import YTCore

@MainActor
enum AppFullscreenController {
    static func handle(enter: Bool, session: PlayerSession, log: DebugLog) {
        guard session.request != nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else {
            log.native(.warn, "Fullscreen", "request ignored: no player or no window scene")
            return
        }
        let isLandscape = scene.effectiveGeometry.interfaceOrientation.isLandscape
        guard let target = AppFullscreen.target(enter: enter, isLandscape: isLandscape) else { return }
        session.presentation = AppFullscreen.presentation(entering: target, from: session.presentation)
        let mask: UIInterfaceOrientationMask = target == .landscape ? .landscapeRight : .portrait
        log.native(.info, "Fullscreen", "\(enter ? "enter" : "exit") request → \(target == .landscape ? "landscape" : "portrait")")
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            Task { @MainActor in
                log.native(.warn, "Fullscreen", "rotation refused: \(error.localizedDescription)")
            }
        }
    }
}

// MediaCoordinator — owner: Module D (PLAN.md §6.4). Phase 0 stub.
//
// Module D: AVAudioSession `.playback`/`.moviePlayback` set at launch but NOT activated (D16);
// interruption, route-change and lifecycle observers that send JSCommands; PiP restore → expand.

import YTCore

@MainActor
final class MediaCoordinator {
    private let session: PlayerSession
    private let player: any PlayerControlling
    private let hub: BridgeEventHub

    init(session: PlayerSession, player: any PlayerControlling, hub: BridgeEventHub) {
        self.session = session
        self.player = player
        self.hub = hub
    }

    /// Called once by AppServices after everything is wired. Phase 0 stub: does nothing.
    func start() {}
}

// Sleep timer (PLAN.md §6.4). Owner: Module D.

import Foundation
import Testing
@testable import YTCore

@Suite("Playback › sleep timer")
struct SleepTimerTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func snap(_ status: PlaybackStatus, _ id: String? = "A") -> PlaybackSnapshot {
        PlaybackSnapshot(status: status, position: 10, duration: 200, videoId: id)
    }

    func state(_ id: String? = "A", meta: String? = nil) -> PlaybackState {
        PlaybackState(meta: meta.map { VideoMeta(videoId: $0, title: "t", author: "a") },
                      snapshot: id.map { snap(.playing, $0) } ?? .idle)
    }

    func armed(_ choice: SleepTimer.Choice, playback: PlaybackState? = nil) -> SleepTimer {
        var timer = SleepTimer()
        let r1 = timer.arm(choice, now: t0, playback: playback ?? state())
        #expect(r1)
        return timer
    }

    // MARK: Duration

    @Test("duration: sets the deadline and counts down from the arm time")
    func durationArm() {
        let timer = armed(.minutes(30))
        #expect(timer.mode == .until(deadline: at(1800), armedAt: t0))
        #expect(timer.deadline == at(1800))
        #expect(timer.isArmed)
        #expect(timer.remaining(now: at(600)) == 1200)
        #expect(timer.remaining(now: at(5000)) == 0, "never negative")
    }

    @Test("duration: nothing before the deadline, whatever the playback")
    func durationNotBefore() {
        var timer = armed(.minutes(15))
        for status in PlaybackStatus.allCases {
            let r2 = timer.evaluate(now: at(899.9), snapshot: snap(status))
            #expect(r2 == .none)
        }
        #expect(timer.isArmed)
    }

    @Test("duration: pauses at and after the deadline, then turns off", arguments: [900.0, 901, 4000])
    func durationFires(seconds: TimeInterval) {
        var timer = armed(.minutes(15))
        let r3 = timer.evaluate(now: at(seconds), snapshot: snap(.playing))
        #expect(r3 == .pause(reason: "time is up"))
        #expect(timer.mode == .off)
        let r4 = timer.evaluate(now: at(seconds + 1), snapshot: snap(.playing))
        #expect(r4 == .none, "fires once")
    }

    @Test("duration: a passed deadline pauses even if the snapshot says paused (stale state is not trusted)")
    func durationStaleSnapshot() {
        var timer = armed(.minutes(15))
        let r5 = timer.evaluate(now: at(1000), snapshot: snap(.paused))
        #expect(r5 == .pause(reason: "time is up"))
        #expect(!timer.isArmed)
    }

    @Test("duration: a different video playing doesn't fire it early")
    func durationIgnoresVideoChange() {
        var timer = armed(.minutes(15))
        let r6 = timer.evaluate(now: at(10), snapshot: snap(.playing, "B"))
        #expect(r6 == .none)
        let r7 = timer.evaluate(now: at(10), snapshot: snap(.ended, "B"))
        #expect(r7 == .none)
        #expect(timer.isArmed)
    }

    @Test("duration: non-positive minutes are refused", arguments: [0, -5])
    func durationRefused(minutes: Int) {
        var timer = SleepTimer()
        let r8 = timer.arm(.minutes(minutes), now: t0, playback: state())
        #expect(!r8)
        #expect(timer.mode == .off)
    }

    @Test("duration: opening another video keeps it armed; closing the player turns it off")
    func durationRequestChanges() {
        var timer = armed(.minutes(30))
        timer.requestChanged(to: "B")
        #expect(timer.isArmed)
        timer.requestChanged(to: nil)
        #expect(timer.mode == .off)
    }

    @Test("presets are the menu's durations")
    func presets() {
        #expect(SleepTimer.presetMinutes == [15, 30, 45, 60, 90])
    }

    // MARK: End of video

    @Test("end of video: arms on the snapshot's videoId, else the metadata's")
    func endArm() {
        #expect(armed(.endOfVideo).mode == .endOfVideo(videoId: "A"))
        #expect(armed(.endOfVideo, playback: state(nil, meta: "M")).mode == .endOfVideo(videoId: "M"))
        #expect(armed(.endOfVideo).deadline == nil)
        #expect(armed(.endOfVideo).remaining(now: t0) == nil)
    }

    @Test("end of video: refused when nothing is loaded")
    func endNothingLoaded() {
        var timer = SleepTimer()
        #expect(SleepTimer.currentVideoId(of: state(nil)) == nil)
        let r9 = timer.arm(.endOfVideo, now: t0, playback: state(nil))
        #expect(!r9)
        #expect(timer.mode == .off)
    }

    @Test("end of video: pauses when the armed video ends", arguments: ["A", nil] as [String?])
    func endFiresOnEnded(id: String?) {
        var timer = armed(.endOfVideo)
        let r10 = timer.evaluate(now: at(100), snapshot: snap(.ended, id))
        #expect(r10 == .pause(reason: "the video ended"))
        #expect(timer.mode == .off)
    }

    @Test("end of video: same-video pause, buffering, loading and playing never fire",
          arguments: [PlaybackStatus.idle, .loading, .playing, .paused, .buffering])
    func endSameVideoNoFire(status: PlaybackStatus) {
        var timer = armed(.endOfVideo)
        let r11 = timer.evaluate(now: at(100), snapshot: snap(status))
        #expect(r11 == .none)
        let r12 = timer.evaluate(now: at(100_000), snapshot: snap(status))
        #expect(r12 == .none, "no deadline")
        #expect(timer.isArmed)
    }

    @Test("end of video: a nil videoId is never a change", arguments: [PlaybackStatus.idle, .loading, .playing, .paused, .buffering])
    func endNilIdNoFire(status: PlaybackStatus) {
        var timer = armed(.endOfVideo)
        let r13 = timer.evaluate(now: at(5), snapshot: snap(status, nil))
        #expect(r13 == .none)
        #expect(timer.isArmed)
    }

    @Test("end of video: another video playing (autoplay skipped `ended`) is paused", arguments: [PlaybackStatus.playing, .buffering])
    func endFiresOnVideoChange(status: PlaybackStatus) {
        var timer = armed(.endOfVideo)
        let r14 = timer.evaluate(now: at(5), snapshot: snap(status, "B"))
        #expect(r14 == .pause(reason: "another video started"))
        #expect(timer.mode == .off)
        let r15 = timer.evaluate(now: at(6), snapshot: snap(.playing, "B"))
        #expect(r15 == .none, "fires once")
    }

    @Test("end of video: another video still loading or paused waits until it plays", arguments: [PlaybackStatus.loading, .paused, .idle])
    func endVideoChangeNotPlaying(status: PlaybackStatus) {
        var timer = armed(.endOfVideo)
        let r16 = timer.evaluate(now: at(5), snapshot: snap(status, "B"))
        #expect(r16 == .none)
        let r17 = timer.evaluate(now: at(6), snapshot: snap(.playing, "B"))
        #expect(r17 == .pause(reason: "another video started"))
    }

    @Test("end of video: after `ended`, the autoplayed next video is paused once")
    func endAutoplayGuard() {
        var timer = armed(.endOfVideo)
        let r18 = timer.evaluate(now: at(100), snapshot: snap(.ended))
        #expect(r18 == .pause(reason: "the video ended"))
        let r19 = timer.evaluate(now: at(102), snapshot: snap(.ended))
        #expect(r19 == .none)
        let r20 = timer.evaluate(now: at(105), snapshot: snap(.loading, "B"))
        #expect(r20 == .none)
        let r21 = timer.evaluate(now: at(108), snapshot: snap(.playing, "B"))
        #expect(r21 ==
                .pause(reason: "the next video started after the timed video ended"))
        let r22 = timer.evaluate(now: at(110), snapshot: snap(.playing, "B"))
        #expect(r22 == .none, "the user can play it")
        #expect(timer.mode == .off)
    }

    @Test("end of video: the autoplay guard expires")
    func endAutoplayGuardExpires() {
        var timer = armed(.endOfVideo)
        _ = timer.evaluate(now: at(100), snapshot: snap(.ended))
        let r23 = timer.evaluate(now: at(100 + SleepTimer.autoplayGuardSeconds), snapshot: snap(.playing, "B"))
        #expect(r23 == .none)
    }

    @Test("end of video: replaying the ended video is not caught by the guard")
    func endAutoplayGuardSameVideo() {
        var timer = armed(.endOfVideo)
        _ = timer.evaluate(now: at(100), snapshot: snap(.ended))
        let r24 = timer.evaluate(now: at(103), snapshot: snap(.playing))
        #expect(r24 == .none)
    }

    @Test("end of video: a video the user opens from browse turns it off without pausing")
    func endUserOpensAnother() {
        var timer = armed(.endOfVideo)
        timer.requestChanged(to: "B")
        #expect(timer.mode == .off)
        let r25 = timer.evaluate(now: at(5), snapshot: snap(.playing, "B"))
        #expect(r25 == .none)
    }

    @Test("end of video: reopening the same video keeps it armed")
    func endUserReopensSame() {
        var timer = armed(.endOfVideo)
        timer.requestChanged(to: "A")
        #expect(timer.mode == .endOfVideo(videoId: "A"))
    }

    @Test("end of video: a video opened during the autoplay guard is not paused")
    func endGuardClearedByRequest() {
        var timer = armed(.endOfVideo)
        _ = timer.evaluate(now: at(100), snapshot: snap(.ended))
        timer.requestChanged(to: "C")
        let r26 = timer.evaluate(now: at(105), snapshot: snap(.playing, "C"))
        #expect(r26 == .none)
    }

    @Test("end of video: closing the player turns it and its guard off")
    func endClosed() {
        var timer = armed(.endOfVideo)
        timer.requestChanged(to: nil)
        #expect(timer.mode == .off)
        var ended = armed(.endOfVideo)
        _ = ended.evaluate(now: at(100), snapshot: snap(.ended))
        ended.requestChanged(to: nil)
        #expect(ended == SleepTimer())
    }

    // MARK: Disarm and re-arm

    @Test("disarm: turns either mode off; nothing fires afterwards")
    func disarm() {
        for choice in [SleepTimer.Choice.minutes(15), .endOfVideo] {
            var timer = armed(choice)
            timer.disarm()
            #expect(timer == SleepTimer())
            let r27 = timer.evaluate(now: at(10_000), snapshot: snap(.ended, "B"))
            #expect(r27 == .none)
        }
    }

    @Test("re-arm: replaces the earlier setting")
    func rearm() {
        var timer = armed(.minutes(15))
        let r28 = timer.arm(.minutes(60), now: at(60), playback: state())
        #expect(r28)
        #expect(timer.deadline == at(60 + 3600))
        let r29 = timer.evaluate(now: at(900), snapshot: snap(.playing))
        #expect(r29 == .none, "the old deadline is gone")

        let r30 = timer.arm(.endOfVideo, now: at(100), playback: state("B"))
        #expect(r30)
        #expect(timer.mode == .endOfVideo(videoId: "B"))
        let r31 = timer.evaluate(now: at(10_000), snapshot: snap(.playing, "B"))
        #expect(r31 == .none, "no deadline any more")

        let r32 = timer.arm(.minutes(30), now: at(200), playback: state("B"))
        #expect(r32)
        let r33 = timer.evaluate(now: at(300), snapshot: snap(.ended, "B"))
        #expect(r33 == .none, "end of video is gone")
    }

    @Test("re-arm: a refused end-of-video keeps the earlier setting")
    func rearmRefused() {
        var timer = armed(.minutes(15))
        let r34 = timer.arm(.endOfVideo, now: at(10), playback: state(nil))
        #expect(!r34)
        #expect(timer.deadline == at(900))
    }

    @Test("re-arm: clears a pending autoplay guard")
    func rearmClearsGuard() {
        var timer = armed(.endOfVideo)
        _ = timer.evaluate(now: at(100), snapshot: snap(.ended))
        let r35 = timer.arm(.minutes(30), now: at(101), playback: state())
        #expect(r35)
        let r36 = timer.evaluate(now: at(105), snapshot: snap(.playing, "B"))
        #expect(r36 == .none)
    }
}
